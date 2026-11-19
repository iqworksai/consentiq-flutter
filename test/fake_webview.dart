import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const Key fakeWebViewKey = ValueKey('fake-webview');

/// A web view platform that records what the SDK asks of it and lets a test
/// play the hosted page's side.
class FakeWebViewPlatform extends WebViewPlatform {
  final List<FakeWebViewController> controllers = [];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = FakeWebViewController(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      FakeWebViewWidget(params);
}

class FakeWebViewController extends PlatformWebViewController {
  FakeWebViewController(super.params) : super.implementation();

  JavaScriptMode? javaScriptMode;
  final Map<String, JavaScriptChannelParams> channels = {};
  FakeNavigationDelegate? delegate;
  final List<Uri> loads = [];
  final List<String> scripts = [];
  final List<Color> backgrounds = [];

  /// What `currentUrl()` reports; the last load when null.
  String? pageUrl;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async =>
      this.javaScriptMode = javaScriptMode;

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channels[params.name] = params;

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async =>
      delegate = handler as FakeNavigationDelegate;

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loads.add(params.uri);

  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);

  @override
  Future<String?> currentUrl() async =>
      pageUrl ?? (loads.isEmpty ? null : loads.last.toString());

  @override
  Future<void> setBackgroundColor(Color color) async => backgrounds.add(color);

  void post(Map<String, Object?> message) =>
      channels['ConsentIQFlutter']!.onMessageReceived(
        JavaScriptMessage(message: jsonEncode(message)),
      );
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  WebResourceErrorCallback? onWebResourceError;
  HttpResponseErrorCallback? onHttpError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async =>
      this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async =>
      this.onWebResourceError = onWebResourceError;

  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async =>
      this.onHttpError = onHttpError;
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: fakeWebViewKey);
}
