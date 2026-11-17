import 'dart:convert';

import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

ConsentIQ build(
  FakeServer server, {
  ConsentIQConfig? options,
  FakeCaptcha? captcha,
  String apiUrl = testApiUrl,
}) {
  final config = options ?? const ConsentIQConfig(propertyKey: testPropertyKey);
  return ConsentIQ(
    config,
    apiClient: ConsentIQApiClient(
      propertyKey: config.propertyKey,
      apiUrl: apiUrl,
      client: server.client,
    ),
    storage: ConsentStorage(),
    captchaTokenSource: captcha?.call,
  );
}

FakeServer captchaServer() => FakeServer(
      config: configJson(requireCaptcha: true, turnstileSiteKey: 'site-key'),
    );

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

    test('a lookup network failure never logs the subject id', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'sid-private-42',
      });
      final client = MockClient((request) async {
        if (request.url.path.startsWith('/api/public/consent/')) {
          throw http.ClientException('Connection refused', request.url);
        }
        return jsonResponse(configJson(), 200);
      });
      final consentIQ = ConsentIQ(
        const ConsentIQConfig(propertyKey: testPropertyKey),
        apiClient: ConsentIQApiClient(
          propertyKey: testPropertyKey,
          apiUrl: testApiUrl,
          client: client,
        ),
        storage: ConsentStorage(),
      );

      final logs = await captureLogs(consentIQ.init);

      expect(
        logs,
        contains(
            '[ConsentIQ] Failed to load consent, using local cache: ClientException'),
      );
      expect(logs.join('\n'), isNot(contains('sid-private-42')));
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

    test('no startup warning when the property requires a captcha', () async {
      final captcha = FakeCaptcha();
      final consentIQ = build(captchaServer(), captcha: captcha);

      final logs = await captureLogs(consentIQ.init);

      expect(logs, isEmpty);
      expect(captcha.calls, 0);
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

    test('requireCaptcha: every submit sends a fresh token', () async {
      final server = captchaServer();
      final captcha = FakeCaptcha();
      final consentIQ = build(server, captcha: captcha);
      await consentIQ.init();

      await consentIQ.acceptAll();
      await consentIQ.updateMarketingConsent({'email': true});

      expect(captcha.calls, 2);
      expect(server.submits, hasLength(2));
      for (final submit in server.submits) {
        expect(submit.json['captchaToken'], 'tok');
      }
      expect(await ConsentStorage().loadConsent(), consentIQ.consent);
    });

    test('captcha failure: nothing posted, local state kept, warning logged',
        () async {
      final server = captchaServer();
      var changes = 0;
      ConsentAcceptEvent? accepted;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onConsentChange: (_, __) => changes++,
          onAccept: (e) => accepted = e,
        ),
        captcha: FakeCaptcha(null),
      );
      await consentIQ.init();

      final logs = await captureLogs(consentIQ.acceptAll);

      expect(server.submits, isEmpty);
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(accepted, isNotNull);
      expect(changes, 0);
      expect(await cachedConsent(), isNull);
      expect(logs, ['[ConsentIQ] Captcha check failed; consent not submitted']);
    });

    test('a 428 captcha_required is answered once and the consent recorded',
        () async {
      final server = FakeServer(submitStatuses: [428, 200]);
      final captcha = FakeCaptcha();
      var changes = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onConsentChange: (_, __) => changes++,
        ),
        captcha: captcha,
      );
      await consentIQ.init();

      await consentIQ.acceptAll();

      expect(server.submits, hasLength(2));
      expect(server.submits[0].json.containsKey('captchaToken'), isFalse);
      expect(server.submits[1].json['captchaToken'], 'tok');
      expect(captcha.calls, 1);
      expect(changes, 1);
      expect(await cachedConsent(), isNotNull);
    });

    test('a challenge is retried once only', () async {
      final server = FakeServer(submitStatuses: [428]);
      final captcha = FakeCaptcha();
      final consentIQ = build(server, captcha: captcha);
      await consentIQ.init();

      await captureLogs(consentIQ.acceptAll);

      expect(server.submits, hasLength(2));
      expect(captcha.calls, 1);
      expect(await cachedConsent(), isNull);
    });

    test('a cancelled challenge sends nothing more and keeps local state',
        () async {
      final server = FakeServer(submitStatuses: [428]);
      final consentIQ = build(server, captcha: FakeCaptcha(null));
      await consentIQ.init();

      final logs = await captureLogs(consentIQ.acceptAll);

      expect(server.submits, hasLength(1));
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(await cachedConsent(), isNull);
      expect(logs, ['[ConsentIQ] Captcha check failed; consent not submitted']);
    });

    test('another refusal is not a challenge', () async {
      final server = FakeServer(submitStatus: 403);
      final captcha = FakeCaptcha();
      final consentIQ = build(server, captcha: captcha);
      await consentIQ.init();

      await captureLogs(consentIQ.acceptAll);

      expect(server.submits, hasLength(1));
      expect(captcha.calls, 0);
    });

    test('the identity token goes with every submit, and only when given',
        () async {
      final server = FakeServer();
      final consentIQ = build(
        server,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          identityToken: 'v2.1700000000.abc',
        ),
      );
      await consentIQ.init();
      await consentIQ.acceptAll();
      await consentIQ.rejectAll();
      expect(
        server.submits.map((r) => r.json['identityToken']),
        ['v2.1700000000.abc', 'v2.1700000000.abc'],
      );

      final plain = FakeServer();
      final without = build(plain);
      await without.init();
      await without.acceptAll();
      expect(plain.submits.single.json.containsKey('identityToken'), isFalse);
    });

    test('an app-chosen subject is marked site, a generated one is not',
        () async {
      final server = FakeServer();
      final site = build(
        server,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          subjectId: 'user-42',
        ),
      );
      await site.init();
      await site.acceptAll();
      final generated = build(server);
      await generated.init();
      await generated.acceptAll();

      expect(server.submits.first.json['subjectSource'], 'site');
      expect(server.submits.last.json.containsKey('subjectSource'), isFalse);
    });

    test('an app-chosen subject id with a colon is refused at init', () async {
      final server = FakeServer();
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          subjectId: 'site:user-42',
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await consentIQ.acceptAll();

      expect(consentIQ.subjectId, isNull);
      expect(server.submits, isEmpty);
      expect(errors.single.source, 'config');
      expect(errors.single.code, 'invalid-subject-id');
    });

    test('no captcha required: token source unused, no captchaToken key',
        () async {
      for (final config in [
        configJson(),
        configJson(requireCaptcha: true),
        configJson(turnstileSiteKey: 'site-key'),
      ]) {
        final server = FakeServer(config: config);
        final captcha = FakeCaptcha();
        final consentIQ = build(server, captcha: captcha);
        await consentIQ.init();

        await consentIQ.acceptAll();

        expect(captcha.calls, 0);
        expect(server.submits.single.json.containsKey('captchaToken'), isFalse);
      }
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

  group('a decision ConsentIQ asks to resend', () {
    late List<ConsentIQError> errors;
    late int changes;

    setUp(() {
      errors = [];
      changes = 0;
    });

    Future<ConsentIQ> launch(
      FakeServer server, {
      DateTime? at,
      FakeCaptcha? captcha,
      String? subjectId,
      String apiUrl = testApiUrl,
    }) async {
      final consentIQ = build(
        server,
        apiUrl: apiUrl,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          subjectId: subjectId,
          autoShow: false,
          onConsentChange: (_, __) => changes++,
          onError: errors.add,
        ),
        captcha: captcha,
      );
      if (at != null) consentIQ.clock = () => at;
      await consentIQ.init();
      return consentIQ;
    }

    Future<String?> pending() async =>
        (await SharedPreferences.getInstance()).getString('consentiq_pending');

    test('429 keeps it, and the next launch sends it without a captcha',
        () async {
      final first = FakeServer(submitStatus: 429);
      await captureLogs(() async => (await launch(first)).acceptAll());
      expect(await pending(), isNotNull);
      expect(changes, 0);

      final second = FakeServer();
      final captcha = FakeCaptcha();
      final relaunched = await launch(second, captcha: captcha);

      expect(second.submits, hasLength(1));
      expect(second.submits.single.json.containsKey('captchaToken'), isFalse);
      expect(second.submits.single.json['cookieConsents']['analytics'], isTrue);
      expect(await pending(), isNull);
      expect(relaunched.hasConsent('analytics'), isTrue);
      expect(await cachedConsent(), isNotNull);
      expect(changes, 1);
      expect(captcha.calls, 0);
    });

    test('the retry is quiet on a challenge and stops after three launches',
        () async {
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429))).acceptAll());

      final challenging = FakeServer(submitStatuses: [428]);
      final captcha = FakeCaptcha();
      for (var i = 0; i < 3; i++) {
        await launch(challenging, captcha: captcha);
      }
      expect(captcha.calls, 0);
      expect(challenging.submits, hasLength(3));
      expect(jsonDecode((await pending())!)['attempts'], 3);

      await launch(challenging, captcha: captcha);
      expect(challenging.submits, hasLength(3));
      expect(await pending(), isNull);
    });

    test('a decision older than seven days is dropped', () async {
      final start = DateTime(2026, 1, 1);
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429), at: start)).acceptAll());

      final later = FakeServer();
      await launch(later, at: start.add(const Duration(days: 8)));

      expect(later.submits, isEmpty);
      expect(await pending(), isNull);
    });

    test('400, 404, 409 and 422 drop it', () async {
      for (final status in [400, 404, 409, 422]) {
        await captureLogs(() async =>
            (await launch(FakeServer(submitStatus: 429))).acceptAll());
        expect(await pending(), isNotNull, reason: '$status');

        await captureLogs(() async =>
            (await launch(FakeServer(submitStatus: status))).rejectAll());
        expect(await pending(), isNull, reason: '$status');
      }
    });

    test('403 reaches the app and is not retried', () async {
      final refusing = FakeServer(
        submitStatus: 403,
        submitBody: const {'error': 'Identity token did not verify'},
      );
      await captureLogs(() async => (await launch(refusing)).acceptAll());
      final next = FakeServer();
      await launch(next);

      expect(next.submits, isEmpty);
      expect(errors.single.source, 'consent');
      expect(errors.single.code, 'refused');
      expect(errors.single.message, 'Identity token did not verify');
      expect(await pending(), isNull);
    });

    test('a 403 to the retry reaches the app too', () async {
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429))).acceptAll());

      await captureLogs(() => launch(FakeServer(
            submitStatus: 403,
            submitBody: const {'error': 'Verified identity required'},
          )));

      expect(errors.single.message, 'Verified identity required');
      expect(await pending(), isNull);
    });

    test('a property that requires a captcha keeps nothing to retry', () async {
      await captureLogs(() async => (await launch(
            FakeServer(
              config: configJson(
                  requireCaptcha: true, turnstileSiteKey: 'site-key'),
              submitStatus: 429,
            ),
            captcha: FakeCaptcha(),
          ))
              .acceptAll());

      expect(await pending(), isNull);
    });

    test('it is never sent for someone else', () async {
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429), subjectId: 'user-a'))
              .acceptAll());
      expect(await pending(), isNotNull);

      final next = FakeServer();
      await launch(next, subjectId: 'user-b');

      expect(next.submits, isEmpty);
      expect(await pending(), isNull);
    });

    test('it is never sent to another server', () async {
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429), subjectId: 'user-a'))
              .acceptAll());

      final next = FakeServer();
      await launch(next,
          subjectId: 'user-a', apiUrl: 'https://staging.example.test');

      expect(next.submits, isEmpty);
      expect(await pending(), isNull);
    });

    test('a new decision replaces one still waiting', () async {
      final consentIQ = await launch(FakeServer(submitStatuses: [429, 500]));
      await captureLogs(() => consentIQ.acceptAll());
      expect(await pending(), isNotNull);

      await captureLogs(() => consentIQ.rejectAll());

      expect(await pending(), isNull);
    });

    test('a newer record on ConsentIQ wins over it', () async {
      final decidedAt = DateTime.utc(2025, 6, 1);
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429), at: decidedAt))
              .acceptAll());

      final next = FakeServer(consent: savedConsentJson());
      await launch(next, at: decidedAt.add(const Duration(minutes: 1)));

      expect(next.submits, isEmpty,
          reason: 'the record dated 2026-01-01 is newer than the decision');
      expect(await pending(), isNull);
    });

    test('an older record on ConsentIQ does not stop the resend', () async {
      final decidedAt = DateTime.utc(2027, 1, 1);
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429), at: decidedAt))
              .acceptAll());

      final next = FakeServer(consent: savedConsentJson());
      await launch(next, at: decidedAt.add(const Duration(minutes: 1)));

      expect(next.submits, hasLength(1));
      expect(await pending(), isNull);
    });

    test('a 429 that arrives after a reset is ignored', () async {
      late ConsentIQ consentIQ;
      final server = FakeServer(
        submitStatus: 429,
        onSubmit: () => consentIQ.resetConsent(),
      );
      consentIQ = await launch(server);

      await captureLogs(() => consentIQ.acceptAll());

      expect(await pending(), isNull);
    });

    test('a decision stored by an older version is discarded', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_pending':
            '{"cookieConsents":{},"marketingConsents":{},"attempts":0,"createdAt":0}',
      });

      expect(await ConsentStorage().loadPending(), isNull);
      expect(await pending(), isNull);
    });

    test('clearAll forgets it', () async {
      await captureLogs(() async =>
          (await launch(FakeServer(submitStatus: 429))).acceptAll());

      await ConsentStorage().clearAll();

      expect(await pending(), isNull);
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
