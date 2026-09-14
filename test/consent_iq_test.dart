import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

ConsentIQ build(FakeServer server, {ConsentIQConfig? options}) {
  final config = options ?? const ConsentIQConfig(propertyKey: testPropertyKey);
  return ConsentIQ(
    config,
    apiClient: ConsentIQApiClient(
      propertyKey: config.propertyKey,
      apiUrl: testApiUrl,
      client: server.client,
    ),
    storage: ConsentStorage(),
  );
}

Future<String?> cachedConsent() async =>
    (await SharedPreferences.getInstance()).getString('consentiq_consent');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('init', () {
    test('never given: shows the sheet and fires onOpen', () async {
      final server = FakeServer();
      var opened = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onOpen: () => opened++,
        ),
      );
      final notifications = <bool>[];
      consentIQ.addListener(() => notifications.add(consentIQ.isSheetVisible));

      await consentIQ.init();

      expect(consentIQ.isLoading, isFalse);
      expect(consentIQ.config, isNotNull);
      expect(consentIQ.regulation, 'DPDPA');
      expect(consentIQ.language, 'en');
      expect(consentIQ.subjectId, isNotNull);
      expect(consentIQ.isSheetVisible, isTrue);
      expect(opened, 1);
      expect(consentIQ.consent, defaultConsentState());
      expect(notifications, [false, true]);
      expect(server.requests.map((r) => r.url), [
        '$testApiUrl/api/public/config/$testPropertyKey',
        '$testApiUrl/api/public/consent/$testPropertyKey/${consentIQ.subjectId}',
      ]);
      expect(await cachedConsent(), isNull);
    });

    test('existing server consent: no sheet, state adopted, cache written',
        () async {
      final server = FakeServer(consent: savedConsentJson());
      var opened = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onOpen: () => opened++,
        ),
      );

      await consentIQ.init();

      expect(consentIQ.isSheetVisible, isFalse);
      expect(opened, 0);
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.hasConsent('marketing'), isFalse);
      expect(consentIQ.hasConsent('necessary'), isTrue);
      expect(consentIQ.hasMarketingConsent('email'), isTrue);
      expect(await cachedConsent(), isNotNull);
      expect(await ConsentStorage().loadConsent(), {
        'necessary': true,
        'analytics': true,
        'marketing': false,
      });
    });

    test('expired: cache cleared, subject id kept, sheet shown', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'sid-1',
        'consentiq_consent': '{"necessary":true,"analytics":true}',
      });
      final server = FakeServer(
        consent: const {'consent': null, 'expired': true},
      );
      final consentIQ = build(server);

      await consentIQ.init();

      expect(consentIQ.subjectId, 'sid-1');
      expect(consentIQ.isSheetVisible, isTrue);
      expect(consentIQ.hasConsent('analytics'), isFalse);
      expect(await cachedConsent(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_subject_id'), 'sid-1');
    });

    test('local cache with no server consent: adopted, no sheet', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'sid-1',
        'consentiq_consent': '{"necessary":true,"analytics":true}',
      });
      final server = FakeServer();
      final consentIQ = build(server);

      await consentIQ.init();

      expect(consentIQ.isSheetVisible, isFalse);
      expect(consentIQ.hasConsent('analytics'), isTrue);
    });

    test('consent lookup failure falls back to the local cache', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'sid-1',
        'consentiq_consent': '{"necessary":true,"analytics":true}',
      });
      final server = FakeServer(consentStatus: 500);
      final consentIQ = build(server);

      final logs = await captureLogs(consentIQ.init);

      expect(consentIQ.isSheetVisible, isFalse);
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(logs.where((l) => l.startsWith('[ConsentIQ] Failed to load')),
          hasLength(1));
    });

    test('config failure leaves the app usable and logs once', () async {
      final server = FakeServer(configStatus: 404);
      final consentIQ = build(server);

      final logs = await captureLogs(consentIQ.init);

      expect(consentIQ.isLoading, isFalse);
      expect(consentIQ.config, isNull);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(consentIQ.consent, defaultConsentState());
      expect(logs, hasLength(1));
      expect(logs.single, startsWith('[ConsentIQ] Failed to initialize'));
    });

    test('autoShow false never shows the sheet', () async {
      final consentIQ = build(
        FakeServer(),
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          autoShow: false,
        ),
      );

      await consentIQ.init();

      expect(consentIQ.isSheetVisible, isFalse);
    });

    test('language: caller override beats property default beats en', () async {
      final overridden = build(
        FakeServer(),
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          language: 'ar',
        ),
      );
      await overridden.init();
      expect(overridden.language, 'ar');
      expect(overridden.isRtl, isTrue);

      final fromProperty = build(
        FakeServer(config: configJson(defaultLanguage: 'hi')),
      );
      await fromProperty.init();
      expect(fromProperty.language, 'hi');

      final fallback = build(
        FakeServer(config: configJson(defaultLanguage: null)),
      );
      await fallback.init();
      expect(fallback.language, 'en');
    });

    test('a caller-supplied subject id is used verbatim', () async {
      final server = FakeServer();
      final consentIQ = build(
        server,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          subjectId: 'app-user-42',
        ),
      );

      await consentIQ.init();

      expect(consentIQ.subjectId, 'app-user-42');
      expect(server.requests.last.url, endsWith('/app-user-42'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_subject_id'), isNull);
    });

    test('autoGenerateSubjectId false skips the consent lookup', () async {
      final server = FakeServer();
      final consentIQ = build(
        server,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          autoGenerateSubjectId: false,
        ),
      );

      await consentIQ.init();

      expect(consentIQ.subjectId, isNull);
      expect(server.requests, hasLength(1));
      expect(consentIQ.isSheetVisible, isTrue);
    });

    test('captcha warning is logged exactly once', () async {
      final consentIQ = build(
        FakeServer(config: configJson(requireCaptcha: true)),
      );

      final logs = await captureLogs(() async {
        await consentIQ.init();
        await consentIQ.init();
      });

      expect(
          logs.where((l) => l == '[ConsentIQ] $captchaWarning'), hasLength(1));
      expect(
        captchaWarning,
        'This property requires a captcha, which mobile SDKs cannot satisfy. '
        'Turn off "Require captcha" for this property in the ConsentIQ '
        'dashboard.',
      );
    });

    test('no captcha warning when the property does not require one', () async {
      final consentIQ = build(FakeServer());

      final logs = await captureLogs(consentIQ.init);

      expect(logs, isEmpty);
    });

    test('init runs once', () async {
      final server = FakeServer();
      final consentIQ = build(server);

      await Future.wait([consentIQ.init(), consentIQ.init()]);
      await consentIQ.init();

      expect(server.requests.where((r) => r.url.contains('/config/')),
          hasLength(1));
    });
  });

  group('writes', () {
    test('acceptAll turns on every enabled category and posts', () async {
      final server = FakeServer();
      ConsentAcceptEvent? accepted;
      ConsentState? changed;
      MarketingConsentState? changedMarketing;
      var closed = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onAccept: (e) => accepted = e,
          onConsentChange: (c, m) {
            changed = c;
            changedMarketing = m;
          },
          onClose: () => closed++,
        ),
      );
      await consentIQ.init();
      expect(consentIQ.isSheetVisible, isTrue);

      await consentIQ.acceptAll();

      expect(consentIQ.isSheetVisible, isFalse);
      expect(closed, 0);
      expect(consentIQ.consent, {
        'necessary': true,
        'analytics': true,
        'marketing': true,
        'preferences': false,
        'social': false,
      });
      expect(accepted?.scope, ConsentScope.all);
      expect(accepted?.consent, consentIQ.consent);
      expect(changed, consentIQ.consent);
      expect(changedMarketing, isEmpty);
      final submit = server.submits.single.json;
      expect(submit['propertyKey'], testPropertyKey);
      expect(submit['subjectId'], consentIQ.subjectId);
      expect(submit['consentMethod'], 'sdk');
      expect(submit['cookieConsents'], consentIQ.consent);
      expect(submit['marketingConsents'], isEmpty);
      expect(await ConsentStorage().loadConsent(), consentIQ.consent);
    });

    test('rejectAll keeps only necessary and carries the marketing map',
        () async {
      final server = FakeServer(consent: savedConsentJson());
      ConsentRejectEvent? rejected;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onReject: (e) => rejected = e,
        ),
      );
      await consentIQ.init();
      expect(consentIQ.hasConsent('analytics'), isTrue);

      await consentIQ.rejectAll();

      expect(consentIQ.consent, defaultConsentState());
      expect(rejected?.consent, defaultConsentState());
      expect(consentIQ.isSheetVisible, isFalse);
      final submit = server.submits.single.json;
      expect(submit['cookieConsents'], defaultConsentState());
      expect(submit['marketingConsents'], {'email': true});
    });

    test('savePreferences forces necessary, closes and reports onSave',
        () async {
      final server = FakeServer();
      ConsentSaveEvent? saved;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onSave: (e) => saved = e,
        ),
      );
      await consentIQ.init();

      await consentIQ.savePreferences({
        'necessary': false,
        'analytics': true,
        'marketing': false,
      });

      expect(consentIQ.isSheetVisible, isFalse);
      expect(consentIQ.consent, {
        'necessary': true,
        'analytics': true,
        'marketing': false,
      });
      expect(saved?.consent, consentIQ.consent);
      expect(server.submits.single.json['cookieConsents'], consentIQ.consent);
    });

    test('updateConsent merges and updateMarketingConsent posts both maps',
        () async {
      final server = FakeServer();
      final consentIQ = build(server);
      await consentIQ.init();

      await consentIQ.updateConsent({'analytics': true, 'necessary': false});
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.hasConsent('necessary'), isTrue);
      expect(consentIQ.isSheetVisible, isTrue);

      await consentIQ.updateMarketingConsent({'email': true});
      expect(consentIQ.hasMarketingConsent('email'), isTrue);
      expect(consentIQ.hasMarketingConsent('sms'), isFalse);

      expect(server.submits, hasLength(2));
      expect(server.submits.last.json['cookieConsents'], consentIQ.consent);
      expect(server.submits.last.json['marketingConsents'], {'email': true});
    });

    test('a failed POST logs, keeps local state and skips the cache', () async {
      final server = FakeServer(submitStatus: 400);
      var changes = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onConsentChange: (_, __) => changes++,
        ),
      );
      await consentIQ.init();

      final logs = await captureLogs(consentIQ.acceptAll);

      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(changes, 0);
      expect(await cachedConsent(), isNull);
      expect(logs, hasLength(1));
      expect(logs.single, startsWith('[ConsentIQ] Failed to submit consent'));
    });

    test('without a subject id nothing is posted', () async {
      final server = FakeServer();
      final consentIQ = build(
        server,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          autoGenerateSubjectId: false,
        ),
      );
      await consentIQ.init();

      await consentIQ.acceptAll();

      expect(server.submits, isEmpty);
      expect(consentIQ.hasConsent('analytics'), isTrue);
    });
  });

  group('sheet controls', () {
    test('showSheet fires onOpen, hideSheet fires nothing, dismiss onClose',
        () async {
      var opened = 0;
      var closed = 0;
      final consentIQ = build(
        FakeServer(consent: savedConsentJson()),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onOpen: () => opened++,
          onClose: () => closed++,
        ),
      );
      await consentIQ.init();
      expect(opened, 0);

      consentIQ.showSheet();
      expect(consentIQ.isSheetVisible, isTrue);
      expect(opened, 1);

      consentIQ.hideSheet();
      expect(consentIQ.isSheetVisible, isFalse);
      expect(closed, 0);

      consentIQ.showSheet();
      consentIQ.dismissSheet();
      expect(consentIQ.isSheetVisible, isFalse);
      expect(closed, 1);

      consentIQ.dismissSheet();
      expect(closed, 1);
    });

    test('resetConsent restores defaults and rotates to a fresh subject id',
        () async {
      final consentIQ = build(FakeServer(consent: savedConsentJson()));
      await consentIQ.init();
      expect(consentIQ.hasConsent('analytics'), isTrue);
      final before = consentIQ.subjectId;

      await consentIQ.resetConsent();

      expect(consentIQ.consent, defaultConsentState());
      expect(consentIQ.marketingConsent, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_consent'), isNull);
      expect(consentIQ.subjectId, isNotNull);
      expect(consentIQ.subjectId, isNot(before));
      expect(prefs.getString('consentiq_subject_id'), consentIQ.subjectId);
    });
  });
}
