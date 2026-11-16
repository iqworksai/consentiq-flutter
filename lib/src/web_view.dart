import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// The JavaScript channel the hosted pages post to.
const String webViewChannel = 'ConsentIQFlutter';

/// Whether [url], the web view's current page, is [page] on its origin. A
/// channel message carries no origin of its own, so this is how a message is
/// tied to the page that sent it.
bool isHostedPage(String? url, Uri page) {
  final uri = url == null ? null : Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.scheme == page.scheme &&
      uri.host == page.host &&
      uri.port == page.port &&
      uri.path == page.path;
}

/// The navigation rule both hosted pages share: [page] itself in the main
/// frame, Turnstile and blank documents in subframes, nothing else. A
/// main-frame http(s) link elsewhere goes to [onExternal] when given.
NavigationDecision decideHostedNavigation(
  NavigationRequest request,
  Uri page, {
  void Function(Uri uri)? onExternal,
}) {
  final uri = Uri.tryParse(request.url);
  if (uri == null) return NavigationDecision.prevent;
  if (request.isMainFrame) {
    if (uri == page) return NavigationDecision.navigate;
    if (onExternal != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      onExternal(uri);
    }
    return NavigationDecision.prevent;
  }
  final allowed = request.url == 'about:blank' ||
      request.url == 'about:srcdoc' ||
      (uri.scheme == 'https' && uri.host == 'challenges.cloudflare.com');
  return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
}

/// Hands [onMessage] each channel message, one at a time and in order, but
/// only while the web view's current page is [page].
class HostedPageChannel {
  HostedPageChannel(this.page, this.onMessage);

  final Uri page;
  final void Function(String message) onMessage;
  WebViewController? webView;
  Future<void> _inbox = Future<void>.value();

  void receive(JavaScriptMessage message) {
    _inbox = _inbox
        .then((_) => _deliver(message.message))
        .onError<Object>((_, __) {});
  }

  Future<void> _deliver(String message) async {
    final webView = this.webView;
    if (webView == null) return;
    try {
      if (!isHostedPage(await webView.currentUrl(), page)) return;
    } catch (_) {
      return;
    }
    onMessage(message);
  }
}

/// The web views loaded off screen, displayed by the first mounted
/// [HiddenWebViewHost].
class HiddenWebViews extends ChangeNotifier {
  HiddenWebViews._();

  static final HiddenWebViews instance = HiddenWebViews._();

  final List<WebViewController> controllers = [];
  final List<Object> hosts = [];

  /// The web view shown over the app for a visitor to interact with, and what
  /// its close button does.
  WebViewController? revealed;
  void Function()? _onCancel;

  void reveal(WebViewController controller,
      {required void Function() onCancel}) {
    revealed = controller;
    _onCancel = onCancel;
    notifyListeners();
  }

  void conceal(WebViewController controller) {
    if (!identical(revealed, controller)) return;
    revealed = null;
    _onCancel = null;
    notifyListeners();
  }

  void cancel() => _onCancel?.call();

  void add(WebViewController controller) {
    if (controllers.contains(controller)) return;
    controllers.add(controller);
    notifyListeners();
  }

  void remove(WebViewController controller) {
    if (controllers.remove(controller)) notifyListeners();
  }

  void clear() {
    controllers.clear();
    revealed = null;
    _onCancel = null;
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

/// Renders [child] as is, plus the hidden web views while any are needed.
/// Only the first mounted host displays them, since a web view can show in
/// one place at a time.
class HiddenWebViewHost extends StatefulWidget {
  const HiddenWebViewHost({super.key, required this.child});

  final Widget child;

  @override
  State<HiddenWebViewHost> createState() => _HiddenWebViewHostState();
}

class _HiddenWebViewHostState extends State<HiddenWebViewHost> {
  static HiddenWebViews get _registry => HiddenWebViews.instance;

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
        : const <WebViewController>[];
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
          if (identical(controller, _registry.revealed))
            Positioned.fill(
              key: ObjectKey(controller),
              child: _RevealedChallenge(
                controller: controller,
                onCancel: _registry.cancel,
              ),
            )
          else
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
                      child: WebViewWidget(controller: controller),
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// A challenge Cloudflare wants the visitor to interact with, shown over the
/// app with a button that gives up on it.
class _RevealedChallenge extends StatelessWidget {
  const _RevealedChallenge({required this.controller, required this.onCancel});

  final WebViewController controller;
  final void Function() onCancel;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0x66000000),
        child: Center(
          child: SizedBox(
            width: 320,
            height: 140,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFFFFFFF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: Semantics(
                      button: true,
                      label: 'Cancel',
                      child: GestureDetector(
                        key: const ValueKey('consentiq-captcha-cancel'),
                        behavior: HitTestBehavior.opaque,
                        onTap: onCancel,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '\u2715',
                            style: TextStyle(
                                fontSize: 18, color: Color(0xFF444444)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: WebViewWidget(controller: controller)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
