import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'consent_state.dart';
import 'json.dart';
import 'web_view.dart';

const String tcfPagePath = '/api/public/tcf/mobile';
const Duration tcfReadyTimeout = Duration(seconds: 15);

// The page reads the config and the vendor list before it can answer.
const Duration tcfAnswerTimeout = Duration(seconds: 45);

/// The page's code when its own config read finds TCF switched off.
const String tcfOffCode = 'tcf-off';

const Color tcfLightBackground = Color(0xFFFFFFFF);
const Color tcfDarkBackground = Color(0xFF111827);

Uri tcfPageUrl(String apiUrl, String propertyKey) => Uri.parse(
    '$apiUrl$tcfPagePath?key=${Uri.encodeQueryComponent(propertyKey)}');

/// The hosted page's own background, so nothing flashes before it paints.
Color tcfBackground(Brightness brightness) =>
    brightness == Brightness.dark ? tcfDarkBackground : tcfLightBackground;

/// A message from the hosted TCF page.
sealed class TcfMessage {
  const TcfMessage();
}

class TcfReady extends TcfMessage {
  const TcfReady();
}

class TcfCurrent extends TcfMessage {
  const TcfCurrent();
}

class TcfShow extends TcfMessage {
  const TcfShow();
}

class TcfNotApplicable extends TcfMessage {
  const TcfNotApplicable();
}

class TcfClosed extends TcfMessage {
  const TcfClosed();
}

class TcfDecision extends TcfMessage {
  const TcfDecision({
    required this.tcString,
    required this.keys,
    required this.stored,
    this.consent,
    this.scope,
  });

  final String tcString;
  final Map<String, Object?> keys;
  final Map<String, dynamic> stored;
  final ConsentState? consent;

  /// `all`, `none` or `custom`: accepted all, rejected all, or saved a
  /// selection. Null when the page sent none.
  final String? scope;
}

class TcfError extends TcfMessage {
  const TcfError(this.code);

  final String code;
}

/// A fresh run token, which only the top page can read and echo.
String newTcfToken() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

/// Parses one page message, or returns null for anything unrecognised.
/// Before the run starts ([token] null) only `ready` is accepted; after it,
/// only messages that echo [token].
TcfMessage? parseTcfMessage(String raw, {required String? token}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final data = asMap(decoded);
  if (token == null) {
    return data['type'] == 'ready' ? const TcfReady() : null;
  }
  if (data['token'] != token) return null;
  switch (data['type']) {
    case 'ready':
      return const TcfReady();
    case 'current':
      return const TcfCurrent();
    case 'show':
      return const TcfShow();
    case 'not-applicable':
      return const TcfNotApplicable();
    case 'closed':
      return const TcfClosed();
    case 'decision':
      final keys = asMap(data['keys']);
      final stored = asMap(data['stored']);
      if (keys.isEmpty || stored.isEmpty) {
        return const TcfError('invalid-decision');
      }
      return TcfDecision(
        tcString: asString(data['tcString']),
        keys: keys,
        stored: stored,
        consent: consentStateFromJson(data['consent']),
        scope: switch (data['scope']) {
          final String s when s == 'all' || s == 'none' || s == 'custom' => s,
          _ => null,
        },
      );
    case 'error':
      return TcfError(asStringOrNull(data['code']) ?? 'error');
  }
  return null;
}

class TcfPageException implements Exception {
  const TcfPageException(this.code);

  final String code;

  @override
  String toString() => 'TcfPageException: $code';
}

typedef ExternalUrlOpener = Future<void> Function(Uri uri);

Future<void> _openExternally(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

/// One run of the hosted TCF page: loaded hidden, then shown full screen by
/// the consent sheet once the page asks to be.
class TcfSession {
  TcfSession({
    required this.pageUrl,
    required this.onMessage,
    ExternalUrlOpener? openExternal,
    String? token,
  })  : token = token ?? newTcfToken(),
        _openExternal = openExternal ?? _openExternally;

  final Uri pageUrl;
  final void Function(TcfMessage message) onMessage;
  final ExternalUrlOpener _openExternal;

  /// Sent with the start call; every later message must echo it.
  final String token;

  /// Whether this run may be closed without a decision.
  bool reopen = false;
  bool _started = false;
  bool _presented = false;
  bool _released = false;
  WebViewController? _webView;
  Timer? _answerTimer;
  final Completer<void> _ready = Completer<void>()..future.ignore();
  late final HostedPageChannel _channel = HostedPageChannel(pageUrl, _receive);

  WebViewController? get webView => _webView;
  bool get isPresented => _presented && !_released;
  bool get isReleased => _released;

  /// Completes on the page's `ready`, or fails if it cannot load.
  Future<void> get ready => _ready.future;

  Future<void> open() async {
    final webView = WebViewController();
    await webView.setJavaScriptMode(JavaScriptMode.unrestricted);
    await webView.setBackgroundColor(tcfBackground(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    ));
    await webView.addJavaScriptChannel(
      webViewChannel,
      onMessageReceived: _channel.receive,
    );
    await webView.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: decideNavigation,
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) _fail('load');
        },
        onHttpError: (error) {
          // WebKit reports only frame loads and leaves the request null.
          final uri = error.request?.uri;
          if (uri == null || uri == pageUrl) _fail('http');
        },
      ),
    );
    if (_released) return;
    _webView = _channel.webView = webView;
    HiddenWebViews.instance.add(webView);
    await webView.loadRequest(pageUrl);
  }

  Future<void> start({
    required String subjectId,
    required Map<String, dynamic>? stored,
    required ConsentState? consent,
  }) async {
    final webView = _webView;
    if (_released || webView == null) return;
    final options = jsonEncode({
      'subjectId': subjectId,
      'stored': stored,
      'consent': consent,
      'reopen': reopen,
      'token': token,
    });
    _started = true;
    _answerTimer = Timer(tcfAnswerTimeout, () {
      if (!_released) onMessage(const TcfError('answer-timeout'));
    });
    await webView.runJavaScript('window.consentiqTcfStart($options)');
  }

  /// Hands the web view from the hidden host to the full-screen page.
  void present() {
    if (_released) return;
    _presented = true;
    final webView = _webView;
    if (webView != null) HiddenWebViews.instance.remove(webView);
  }

  void release() {
    if (_released) return;
    _released = true;
    _answerTimer?.cancel();
    final webView = _webView;
    if (webView != null) HiddenWebViews.instance.remove(webView);
    if (!_ready.isCompleted) {
      _ready.completeError(const TcfPageException('released'));
    }
  }

  // A link on the page, such as a vendor's privacy policy, opens in the
  // browser rather than replacing the page.
  @visibleForTesting
  NavigationDecision decideNavigation(NavigationRequest request) =>
      decideHostedNavigation(
        request,
        pageUrl,
        onExternal: isPresented ? (uri) => unawaited(_openExternal(uri)) : null,
      );

  void _receive(String raw) {
    if (_released) return;
    final message = parseTcfMessage(raw, token: _started ? token : null);
    if (message == null) return;
    if (message is TcfReady) {
      if (!_ready.isCompleted) _ready.complete();
      return;
    }
    _answerTimer?.cancel();
    onMessage(message);
  }

  void _fail(String code) {
    if (_released) return;
    if (!_ready.isCompleted) {
      _ready.completeError(TcfPageException(code));
    } else {
      onMessage(TcfError(code));
    }
  }
}
