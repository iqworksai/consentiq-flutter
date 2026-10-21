import 'dart:async';

import 'package:consentiq/consentiq.dart';
import 'package:consentiq/src/captcha.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview.dart';
import 'fixtures.dart';

final Uri pageUrl = Uri.parse('$testApiUrl/api/public/captcha/mobile');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebViewPlatform platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebViewPlatform.instance = platform = FakeWebViewPlatform();
    CaptchaController.resetForTesting();
  });

  group('CaptchaController', () {
    test('loads the page, waits for ready, executes and returns the token',
        () async {
      final token = CaptchaController.forApiUrl(testApiUrl).token();
      await pumpEventQueue();

      final web = platform.controllers.single;
      expect(web.javaScriptMode, JavaScriptMode.unrestricted);
      expect(web.channels.keys, ['ConsentIQFlutter']);
      expect(web.loads, [pageUrl]);
      expect(web.scripts, isEmpty);

      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(web.scripts, ['window.consentiqExecute()']);

      web.post({'type': 'token', 'token': 't1'});
      expect(await token, 't1');
    });

    test('ignores messages unless the hosted captcha page sent them', () async {
      final token = CaptchaController.forApiUrl(testApiUrl).token();
      var settled = false;
      token.then((_) => settled = true, onError: (Object _) {}).ignore();
      await pumpEventQueue();
      final web = platform.controllers.single;

      web.pageUrl = 'https://evil.test/api/public/captcha/mobile';
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(web.scripts, isEmpty);

      web.pageUrl = null;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(web.scripts, ['window.consentiqExecute()']);

      web.pageUrl = '$testApiUrl/api/public/tcf/mobile';
      web.post({'type': 'token', 'token': 'forged'});
      await pumpEventQueue();
      expect(settled, isFalse);

      web.pageUrl = null;
      web.post({'type': 'token', 'token': 't1'});
      expect(await token, 't1');
    });

    test('one controller per API URL', () {
      expect(
        CaptchaController.forApiUrl(testApiUrl),
        same(CaptchaController.forApiUrl(testApiUrl)),
      );
      expect(
        CaptchaController.forApiUrl(testApiUrl),
        isNot(same(CaptchaController.forApiUrl('https://other.test'))),
      );
    });

    test('requests run one at a time, a fresh execute each, page reused',
        () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      final first = controller.token();
      final second = controller.token();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(web.scripts, hasLength(1));

      web.post({'type': 'token', 'token': 't1'});
      expect(await first, 't1');
      await pumpEventQueue();
      expect(web.scripts, hasLength(2));

      web.post({'type': 'token', 'token': 't2'});
      expect(await second, 't2');
      expect(web.loads, hasLength(1));
    });

    test('a loaded page serves the first request without reloading', () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      controller.loadPage();
      controller.loadPage();
      await pumpEventQueue();
      final web = platform.controllers.single;
      expect(web.loads, [pageUrl]);
      web.post({'type': 'ready'});

      final token = controller.token();
      await pumpEventQueue();
      expect(web.scripts, ['window.consentiqExecute()']);
      web.post({'type': 'token', 'token': 't1'});
      expect(await token, 't1');
      expect(web.loads, hasLength(1));
    });

    test('an error message fails the request and the next one reloads',
        () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      final failed = controller.token();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.post({'type': 'error', 'code': '300030'});
      await expectLater(failed, throwsA(isA<CaptchaException>()));

      final next = controller.token();
      await pumpEventQueue();
      expect(web.loads, hasLength(2));
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.post({'type': 'token', 'token': 't2'});
      expect(await next, 't2');
      expect(platform.controllers, hasLength(1));
    });

    test('a main-frame load error fails the request; a subframe one does not',
        () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      final token = controller.token();
      await pumpEventQueue();
      final delegate = platform.controllers.single.delegate!;
      var failed = false;
      unawaited(token.then((_) {}, onError: (Object _) => failed = true));

      delegate.onWebResourceError!(const WebResourceError(
          errorCode: -2, description: 'x', isForMainFrame: false));
      delegate.onHttpError!(HttpResponseError(
        request: WebResourceRequest(uri: Uri.parse('$testApiUrl/favicon.ico')),
        response: const WebResourceResponse(uri: null, statusCode: 404),
      ));
      await pumpEventQueue();
      expect(failed, isFalse);

      delegate.onWebResourceError!(const WebResourceError(
          errorCode: -2, description: 'x', isForMainFrame: true));
      await expectLater(token, throwsA(isA<CaptchaException>()));
    });

    test('an HTTP error on the page itself fails the request', () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      final token = controller.token();
      await pumpEventQueue();

      platform.controllers.single.delegate!.onHttpError!(HttpResponseError(
        request: WebResourceRequest(uri: pageUrl),
        response: const WebResourceResponse(uri: null, statusCode: 404),
      ));

      await expectLater(token, throwsA(isA<CaptchaException>()));
    });

    test('navigation: the page in the main frame, Turnstile in subframes',
        () async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      controller.loadPage();
      await pumpEventQueue();
      final decide = platform.controllers.single.delegate!.onNavigationRequest!;
      Future<NavigationDecision> check(String url, {bool main = true}) async =>
          decide(NavigationRequest(url: url, isMainFrame: main));

      expect(await check(pageUrl.toString()), NavigationDecision.navigate);
      for (final url in [
        '$pageUrl?next=1',
        '$testApiUrl/',
        'https://evil.test/',
        'https://challenges.cloudflare.com/turnstile/v0/api.js',
        'about:blank',
      ]) {
        expect(await check(url), NavigationDecision.prevent, reason: url);
      }
      for (final url in [
        'https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x',
        'about:blank',
        'about:srcdoc',
      ]) {
        expect(await check(url, main: false), NavigationDecision.navigate,
            reason: url);
      }
      for (final url in [
        'http://challenges.cloudflare.com/x',
        'https://evil.test/',
        'https://challenges.cloudflare.com.evil.test/',
      ]) {
        expect(await check(url, main: false), NavigationDecision.prevent,
            reason: url);
      }
    });

    testWidgets('times out after 15 s and warns once with no provider',
        (tester) async {
      final controller = CaptchaController.forApiUrl(testApiUrl);
      final errors = <Object>[];
      final logs = await captureLogs(() async {
        for (var i = 0; i < 2; i++) {
          unawaited(controller.token().then((_) {}, onError: errors.add));
          await tester.pump(const Duration(seconds: 14));
          expect(errors, hasLength(i));
          await tester.pump(const Duration(seconds: 1));
          expect(errors, hasLength(i + 1));
        }
      });

      expect(errors, everyElement(isA<CaptchaException>()));
      expect(platform.controllers.single.loads, hasLength(2));
      expect(logs, [
        '[ConsentIQ] Captcha needs ConsentIQProvider mounted above the app',
      ]);
    });

    testWidgets('a timeout with a provider mounted does not warn',
        (tester) async {
      await tester.pumpWidget(ConsentIQProvider(
        consentIQ: ConsentIQ(const ConsentIQConfig(propertyKey: 'pk')),
        child: const SizedBox(),
      ));
      final errors = <Object>[];
      final logs = await captureLogs(() async {
        unawaited(CaptchaController.forApiUrl(testApiUrl)
            .token()
            .then((_) {}, onError: errors.add));
        await tester.pump(const Duration(seconds: 15));
      });

      expect(errors, hasLength(1));
      expect(logs, isEmpty);
    });
  });

  group('default token source', () {
    test('ConsentIQ loads the page on the first submit, not on init', () async {
      final server = FakeServer(
        config: configJson(requireCaptcha: true, turnstileSiteKey: 'site-key'),
      );
      final consentIQ = ConsentIQ(
        const ConsentIQConfig(propertyKey: testPropertyKey, apiUrl: testApiUrl),
        apiClient: ConsentIQApiClient(
          propertyKey: testPropertyKey,
          apiUrl: testApiUrl,
          client: server.client,
        ),
        storage: ConsentStorage(),
      );

      await consentIQ.init();
      await pumpEventQueue();
      expect(platform.controllers, isEmpty);

      final accepted = consentIQ.acceptAll();
      await pumpEventQueue();
      final web = platform.controllers.single;
      expect(web.loads, [pageUrl]);
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(server.submits, isEmpty);
      web.post({'type': 'token', 'token': 'page-token'});
      await accepted;

      expect(server.submits.single.json['captchaToken'], 'page-token');
    });

    test('ConsentIQ and FormConsent on one API URL share one web view',
        () async {
      final server = FakeServer(
        config: configJson(requireCaptcha: true, turnstileSiteKey: 'site-key'),
      );
      ConsentIQApiClient client() => ConsentIQApiClient(
            propertyKey: testPropertyKey,
            apiUrl: testApiUrl,
            client: server.client,
          );
      final consentIQ = ConsentIQ(
        const ConsentIQConfig(propertyKey: testPropertyKey),
        apiClient: client(),
        storage: ConsentStorage(),
      );
      final form = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'user-7',
        apiClient: client(),
      );

      await consentIQ.init();
      final submitted = form.submit();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.post({'type': 'token', 'token': 'form-token'});
      expect(await submitted, isNotNull);

      final accepted = consentIQ.acceptAll();
      await pumpEventQueue();
      web.post({'type': 'token', 'token': 'sheet-token'});
      await accepted;

      expect(platform.controllers, hasLength(1));
      expect(web.loads, hasLength(1));
      expect(
        server.submits.map((r) => r.json['captchaToken']),
        ['form-token', 'sheet-token'],
      );
      expect(server.submits.first.json['consentMethod'], 'form');
    });
  });

  group('ConsentIQProvider hosting', () {
    testWidgets('renders its child unchanged when no captcha is needed',
        (tester) async {
      final consentIQ = ConsentIQ(const ConsentIQConfig(propertyKey: 'pk'));
      BoxConstraints? constraints;
      ConsentIQ? provided;
      TextDirection? direction;
      var taps = 0;
      await tester.pumpWidget(ConsentIQProvider(
        consentIQ: consentIQ,
        child: LayoutBuilder(builder: (context, c) {
          constraints = c;
          provided = ConsentIQProvider.of(context);
          direction = Directionality.maybeOf(context);
          return GestureDetector(
            onTap: () => taps++,
            child: const ColoredBox(color: Color(0xFF000000)),
          );
        }),
      ));

      final view = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(constraints, BoxConstraints.tight(view));
      expect(tester.getRect(find.byType(ColoredBox)), Offset.zero & view);
      expect(provided, same(consentIQ));
      expect(direction, isNull);
      expect(find.byType(WebViewWidget), findsNothing);
      await tester.tapAt(const Offset(0.5, 0.5));
      expect(taps, 1);
    });

    testWidgets('mounts one hidden web view and keeps the child state',
        (tester) async {
      final consentIQ = ConsentIQ(const ConsentIQConfig(propertyKey: 'pk'));
      await tester.pumpWidget(ConsentIQProvider(
        consentIQ: consentIQ,
        child: ConsentIQProvider(
          consentIQ: consentIQ,
          child: const _Probe(),
        ),
      ));
      final before = tester.state(find.byType(_Probe));
      expect(find.byKey(fakeWebViewKey), findsNothing);

      CaptchaController.forApiUrl(testApiUrl).loadPage();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(fakeWebViewKey), findsOneWidget);
      expect(tester.getSize(find.byKey(fakeWebViewKey)), const Size(1, 1));
      expect(tester.getTopLeft(find.byKey(fakeWebViewKey)), Offset.zero);
      expect(
        find.ancestor(
          of: find.byKey(fakeWebViewKey),
          matching:
              find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.01),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(fakeWebViewKey),
          matching:
              find.byWidgetPredicate((w) => w is IgnorePointer && w.ignoring),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.byKey(fakeWebViewKey),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      expect(tester.state(find.byType(_Probe)), same(before));
      await tester.tapAt(const Offset(0.5, 0.5));
      expect(tester.state<_ProbeState>(find.byType(_Probe)).taps, 1);
      expect(
        tester.getSize(find.byType(_Probe)),
        tester.view.physicalSize / tester.view.devicePixelRatio,
      );
    });
  });
}

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int taps = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: const SizedBox.expand(),
      );
}
