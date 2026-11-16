import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_client.dart';
import 'json.dart';
import 'log.dart';
import 'models.dart';
import 'web_view.dart';

/// Returns a fresh, single-use captcha token, or throws when none can be had.
typedef CaptchaTokenSource = Future<String> Function();

const String captchaFailedWarning =
    'Captcha check failed; consent not submitted';
const String captchaNoHostWarning =
    'Captcha needs ConsentIQProvider mounted above the app';
const String captchaPagePath = '/api/public/captcha/mobile';
const String captchaChannel = webViewChannel;
const Duration captchaTimeout = Duration(seconds: 15);

const Duration captchaInteractionTimeout = Duration(minutes: 2);

/// The captcha page for [propertyKey]; the key binds each token to the
/// property, so it cannot be spent on another one.
Uri captchaPageUrl(String apiUrl, String propertyKey) =>
    Uri.parse('$apiUrl$captchaPagePath')
        .replace(queryParameters: {'key': propertyKey});

/// ConsentIQ asks for a captcha when a submission looks automated, whatever
/// the property's setting.
bool isCaptchaRequired(Object error) =>
    error is ConsentIQApiException &&
    error.statusCode == 428 &&
    error.message == 'captcha_required';

/// Sends a submission and, when the server answers 428 captcha_required,
/// solves one challenge and sends it once more. Throws [CaptchaException]
/// when that challenge fails; nothing more is sent.
Future<T> submitAnsweringChallenge<T>({
  required String? firstToken,
  required CaptchaTokenSource tokenSource,
  required Future<T> Function(String? captchaToken) send,
}) async {
  try {
    return await send(firstToken);
  } catch (e) {
    if (!isCaptchaRequired(e)) rethrow;
  }
  final String token;
  try {
    token = await tokenSource();
  } on CaptchaException {
    rethrow;
  } catch (_) {
    throw const CaptchaException('failed');
  }
  return send(token);
}

bool requiresCaptcha(PropertyConfig config) =>
    config.requireCaptcha && config.turnstileSiteKey != null;

class CaptchaException implements Exception {
  const CaptchaException(this.code);

  final String code;

  @override
  String toString() => 'CaptchaException: $code';
}

/// Runs the hosted Turnstile page in a hidden web view that a
/// [HiddenWebViewHost] displays. One per API URL for the process, shared by every caller.
class CaptchaController {
  CaptchaController._(this.pageUrl);

  static final Map<Uri, CaptchaController> _byPage = {};
  static HiddenWebViews get _registry => HiddenWebViews.instance;
  static bool _warnedNoHost = false;

  static CaptchaController forProperty(String apiUrl, String propertyKey) {
    final page = captchaPageUrl(apiUrl, propertyKey);
    return _byPage.putIfAbsent(page, () => CaptchaController._(page));
  }

  @visibleForTesting
  static void resetForTesting() {
    _byPage.clear();
    _registry.clear();
    _warnedNoHost = false;
  }

  final Uri pageUrl;
  WebViewController? _webView;
  Future<WebViewController>? _creating;
  Completer<void>? _ready;
  Completer<String>? _token;
  Future<void> _queue = Future<void>.value();
  late final HostedPageChannel _channel =
      HostedPageChannel(pageUrl, _onMessage);

  @visibleForTesting
  void loadPage() => _ensureLoaded();

  /// A fresh token. Requests run one at a time, each with its own timeout.
  Future<String> token() {
    final result = _queue.then((_) => _request());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> _request() async {
    final done = Completer<String>()..future.ignore();
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    var timeout =
        Timer(captchaTimeout, () => fail(const CaptchaException('timeout')));
    _revealNow = () {
      if (_revealed || done.isCompleted) return;
      final webView = _webView;
      if (webView == null) return;
      _revealed = true;
      timeout.cancel();
      timeout = Timer(
        captchaInteractionTimeout,
        () => fail(const CaptchaException('timeout')),
      );
      _registry.reveal(
        webView,
        onCancel: () => fail(const CaptchaException('cancelled')),
      );
    };
    // The challenge stays hidden until the page posts `interactive`: only then
    // does Cloudflare need a click.
    unawaited(_obtain().then(
      (token) {
        if (!done.isCompleted) done.complete(token);
      },
      onError: fail,
    ));
    try {
      return await done.future;
    } catch (e) {
      final timedOut = e is CaptchaException && e.code == 'timeout';
      _reset('failed');
      if (timedOut && _registry.hosts.isEmpty && !_warnedNoHost) {
        _warnedNoHost = true;
        const ConsentIQLogger().warn(captchaNoHostWarning);
      }
      throw e is CaptchaException ? e : const CaptchaException('timeout');
    } finally {
      timeout.cancel();
      _revealNow = null;
      if (_revealed) {
        _revealed = false;
        final webView = _webView;
        if (webView != null) _registry.conceal(webView);
      }
    }
  }

  void Function()? _revealNow;
  bool _revealed = false;

  Future<String> _obtain() async {
    final ready = _ensureLoaded();
    await ready.future;
    if (!identical(ready, _ready)) throw const CaptchaException('reset');
    final token = _token = Completer<String>()..future.ignore();
    await _webView!.runJavaScript('window.consentiqExecute()');
    return token.future;
  }

  Completer<void> _ensureLoaded() {
    final existing = _ready;
    if (existing != null) return existing;
    final ready = _ready = Completer<void>()..future.ignore();
    unawaited(_load(ready));
    return ready;
  }

  Future<void> _load(Completer<void> ready) async {
    try {
      final webView = await (_creating ??= _create());
      await webView.loadRequest(pageUrl);
    } catch (_) {
      if (_webView == null) _creating = null;
      if (identical(ready, _ready)) _reset('load');
    }
  }

  Future<WebViewController> _create() async {
    final webView = WebViewController();
    await webView.setJavaScriptMode(JavaScriptMode.unrestricted);
    await webView.addJavaScriptChannel(
      captchaChannel,
      onMessageReceived: _channel.receive,
    );
    await webView.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) =>
            decideHostedNavigation(request, pageUrl),
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) _reset('load');
        },
        onHttpError: (error) {
          // WebKit reports only frame loads and leaves the request null.
          final uri = error.request?.uri;
          if (uri == null || uri == pageUrl) _reset('http');
        },
      ),
    );
    _webView = _channel.webView = webView;
    _registry.add(webView);
    return webView;
  }

  void _onMessage(String message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    final data = asMap(decoded);
    switch (data['type']) {
      case 'ready':
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
      case 'interactive':
        if (_token != null) _revealNow?.call();
      case 'token':
        final value = asStringOrNull(data['token']);
        final token = _token;
        if (value != null && value.isNotEmpty && token != null) {
          _token = null;
          if (!token.isCompleted) token.complete(value);
        }
      case 'error':
        _reset(asStringOrNull(data['code']) ?? 'error');
    }
  }

  // Fails whatever is waiting and forgets the page, so the next request
  // reloads it.
  void _reset(String code) {
    final error = CaptchaException(code);
    final ready = _ready;
    final token = _token;
    _ready = null;
    _token = null;
    if (ready != null && !ready.isCompleted) ready.completeError(error);
    if (token != null && !token.isCompleted) token.completeError(error);
  }
}
