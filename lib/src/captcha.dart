import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'json.dart';
import 'log.dart';
import 'models.dart';

/// Returns a fresh, single-use captcha token, or throws when none can be had.
typedef CaptchaTokenSource = Future<String> Function();

const String captchaFailedWarning =
    'Captcha check failed; consent not submitted';
const String captchaNoHostWarning =
    'Captcha needs ConsentIQProvider mounted above the app';
const String captchaPagePath = '/api/public/captcha/mobile';
const String captchaChannel = 'ConsentIQFlutter';
const Duration captchaTimeout = Duration(seconds: 15);

bool requiresCaptcha(PropertyConfig config) =>
    config.requireCaptcha && config.turnstileSiteKey != null;

class CaptchaException implements Exception {
  const CaptchaException(this.code);

  final String code;

  @override
  String toString() => 'CaptchaException: $code';
}

/// Runs the hosted Turnstile page in a hidden web view that a [CaptchaHost]
/// displays. One per API URL for the process, shared by every caller.
class CaptchaController {
  CaptchaController._(String apiUrl)
      : pageUrl = Uri.parse('$apiUrl$captchaPagePath');

  static final Map<String, CaptchaController> _byApiUrl = {};
  static final _HostRegistry _registry = _HostRegistry();
  static bool _warnedNoHost = false;

  static CaptchaController forApiUrl(String apiUrl) =>
      _byApiUrl.putIfAbsent(apiUrl, () => CaptchaController._(apiUrl));

  @visibleForTesting
  static void resetForTesting() {
    _byApiUrl.clear();
    _registry.controllers.clear();
    _warnedNoHost = false;
  }

  final Uri pageUrl;
  WebViewController? _webView;
  Future<WebViewController>? _creating;
  Completer<void>? _ready;
  Completer<String>? _token;
  Future<void> _queue = Future<void>.value();

  @visibleForTesting
  void loadPage() => _ensureLoaded();

  /// A fresh token. Requests run one at a time, each with its own timeout.
  Future<String> token() {
    final result = _queue.then((_) => _request());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> _request() async {
    try {
      return await _obtain().timeout(captchaTimeout);
    } catch (e) {
      _reset('failed');
      if (e is TimeoutException && _registry.hosts.isEmpty && !_warnedNoHost) {
        _warnedNoHost = true;
        const ConsentIQLogger().warn(captchaNoHostWarning);
      }
      throw e is CaptchaException ? e : const CaptchaException('timeout');
    }
  }

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
      onMessageReceived: _onMessage,
    );
    await webView.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: _decideNavigation,
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
    _webView = webView;
    _registry.add(this);
    return webView;
  }

  NavigationDecision _decideNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    final allowed = request.isMainFrame
        ? uri == pageUrl
        : uri != null &&
            (uri.toString() == 'about:blank' ||
                uri.toString() == 'about:srcdoc' ||
                (uri.scheme == 'https' &&
                    uri.host == 'challenges.cloudflare.com'));
    return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
  }

  void _onMessage(JavaScriptMessage message) {
    final Object? decoded;
    try {
      decoded = jsonDecode(message.message);
    } on FormatException {
      return;
    }
    final data = asMap(decoded);
    switch (data['type']) {
      case 'ready':
        final ready = _ready;
        if (ready != null && !ready.isCompleted) ready.complete();
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

class _HostRegistry extends ChangeNotifier {
  final List<CaptchaController> controllers = [];
  final List<Object> hosts = [];

  void add(CaptchaController controller) {
    controllers.add(controller);
    notifyListeners();
  }

  bool isActive(Object host) =>
      hosts.isNotEmpty && identical(hosts.first, host);

  void attach(Object host) => hosts.add(host);

  void detach(Object host) {
    final wasActive = isActive(host);
    hosts.remove(host);
    // Unmounting runs while the tree is locked, so the next host takes over
    // after this frame.
    if (wasActive && hosts.isNotEmpty) scheduleMicrotask(notifyListeners);
  }
}

/// Renders [child] as is, plus the hidden captcha web views while any are
/// needed. Only the first mounted host displays them, since a web view can
/// show in one place at a time.
class CaptchaHost extends StatefulWidget {
  const CaptchaHost({super.key, required this.child});

  final Widget child;

  @override
  State<CaptchaHost> createState() => _CaptchaHostState();
}

class _CaptchaHostState extends State<CaptchaHost> {
  static _HostRegistry get _registry => CaptchaController._registry;

  @override
  void initState() {
    super.initState();
    _registry.attach(this);
    _registry.addListener(_changed);
  }

  @override
  void dispose() {
    _registry.removeListener(_changed);
    _registry.detach(this);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controllers = _registry.isActive(this)
        ? _registry.controllers
        : const <CaptchaController>[];
    // The Stack is always there, so the child keeps its element and state
    // when a web view comes or goes. Passthrough keeps its constraints.
    return Stack(
      alignment: Alignment.topLeft,
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        widget.child,
        for (final controller in controllers)
          Positioned(
            key: ObjectKey(controller),
            left: 0,
            top: 0,
            width: 1,
            height: 1,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.01,
                child: ExcludeSemantics(
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: WebViewWidget(controller: controller._webView!),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
