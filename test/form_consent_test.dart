import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

FormConsent buildForm(
  FakeServer server, {
  FakeCaptcha? captcha,
  String? identityToken,
}) =>
    FormConsent(
      propertyKey: testPropertyKey,
      identityToken: identityToken,
      subjectId: 'user-7',
      apiClient: ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      ),
      captchaTokenSource: captcha?.call,
    );

FakeServer captchaServer() => FakeServer(
      config: configJson(requireCaptcha: true, turnstileSiteKey: 'site-key'),
    );

void main() {
  group('FormConsent', () {
    test('marks its subject as the site\'s, and refuses one with a colon',
        () async {
      final server = FakeServer();
      final form = buildForm(server)..setChannel('email', true);
      await form.submit();
      expect(server.submits.single.json['subjectSource'], 'site');

      final refused =
          await FormConsent(propertyKey: testPropertyKey, subjectId: 'site:u1')
              .submit();
      expect(refused, isNull);
      expect(server.submits, hasLength(1));
    });

    test('defaults every channel to false', () {
      final form = FormConsent(propertyKey: testPropertyKey, subjectId: 'u1');

      expect(form.consents, {
        'email': false,
        'sms': false,
        'whatsapp': false,
        'push': false,
      });
    });

    test('toggle and set notify and report changes', () {
      final form = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'u1',
        channels: const ['email', 'sms'],
      );
      final reported = <MarketingConsentState>[];
      var notified = 0;
      form.addListener(() => notified++);
      final withCallback = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'u1',
        onConsentChange: reported.add,
      );

      form.toggleChannel('email');
      form.setChannel('sms', true);
      form.toggleChannel('email');
      withCallback.setChannel('push', true);

      expect(form.consents, {'email': false, 'sms': true});
      expect(notified, 3);
      expect(reported.single['push'], isTrue);
    });

    test('submit posts marketing consents as a user form', () async {
      final server = FakeServer();
      FormConsentResult? submitted;
      final form = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'user-7',
        apiClient: ConsentIQApiClient(
          propertyKey: testPropertyKey,
          apiUrl: testApiUrl,
          client: server.client,
        ),
        onConsentSubmitted: (r) => submitted = r,
      );
      form.setChannel('email', true);

      final result = await form.submit();

      expect(form.isSubmitting, isFalse);
      expect(result?.submission.consentId, 'c-1');
      expect(submitted?.consents['email'], isTrue);
      expect(server.submits.single.json, {
        'propertyKey': testPropertyKey,
        'subjectId': 'user-7',
        'subjectSource': 'site',
        'subjectType': 'user',
        'marketingConsents': {
          'email': true,
          'sms': false,
          'whatsapp': false,
          'push': false,
        },
        'consentMethod': 'form',
      });
    });

    test('submit returns null and logs on failure', () async {
      final server = FakeServer(submitStatus: 500);
      final form = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'user-7',
        apiClient: ConsentIQApiClient(
          propertyKey: testPropertyKey,
          apiUrl: testApiUrl,
          client: server.client,
        ),
      );

      FormConsentResult? result;
      final logs = await captureLogs(() async => result = await form.submit());

      expect(result, isNull);
      expect(logs.single, startsWith('[ConsentIQ] Failed to submit form'));
    });

    test('requireCaptcha: config loaded once, a fresh token per submit',
        () async {
      final server = captchaServer();
      final captcha = FakeCaptcha();
      final form = buildForm(server, captcha: captcha);

      expect(await form.submit(), isNotNull);
      expect(await form.submit(), isNotNull);

      expect(captcha.calls, 2);
      expect(server.requests.where((r) => r.url.contains('/config/')),
          hasLength(1));
      expect(server.submits, hasLength(2));
      for (final submit in server.submits) {
        expect(submit.json['captchaToken'], 'tok');
      }
    });

    test('a 428 is answered once, with the identity token on both sends',
        () async {
      final server = FakeServer(submitStatuses: [428, 200]);
      final captcha = FakeCaptcha();
      final form =
          buildForm(server, captcha: captcha, identityToken: 'v2.1.sig');

      expect(await form.submit(), isNotNull);

      expect(server.submits, hasLength(2));
      expect(server.submits[1].json['captchaToken'], 'tok');
      expect(
        server.submits.map((r) => r.json['identityToken']),
        ['v2.1.sig', 'v2.1.sig'],
      );
      expect(captcha.calls, 1);
    });

    test('a cancelled challenge returns null and sends nothing more', () async {
      final server = FakeServer(submitStatuses: [428]);
      final form = buildForm(server, captcha: FakeCaptcha(null));

      final logs =
          await captureLogs(() async => expect(await form.submit(), isNull));

      expect(server.submits, hasLength(1));
      expect(logs, ['[ConsentIQ] Captcha check failed; consent not submitted']);
    });

    test('captcha failure: nothing posted, null returned, warning logged',
        () async {
      final server = captchaServer();
      final form = buildForm(server, captcha: FakeCaptcha(null));

      FormConsentResult? result;
      final logs = await captureLogs(() async => result = await form.submit());

      expect(result, isNull);
      expect(form.isSubmitting, isFalse);
      expect(server.submits, isEmpty);
      expect(logs, ['[ConsentIQ] Captcha check failed; consent not submitted']);
    });

    test('no captcha required: token source unused, no captchaToken key',
        () async {
      final server = FakeServer();
      final captcha = FakeCaptcha();
      final form = buildForm(server, captcha: captcha);

      await form.submit();

      expect(captcha.calls, 0);
      expect(server.submits.single.json.containsKey('captchaToken'), isFalse);
    });

    test('a failed config load is retried and the submit still goes out',
        () async {
      final server = FakeServer(configStatus: 500);
      final captcha = FakeCaptcha();
      final form = buildForm(server, captcha: captcha);

      final logs = await captureLogs(() async {
        await form.submit();
        await form.submit();
      });

      expect(captcha.calls, 0);
      expect(server.requests.where((r) => r.url.contains('/config/')),
          hasLength(2));
      expect(server.submits, hasLength(2));
      expect(
          logs, everyElement(startsWith('[ConsentIQ] Failed to load config')));
    });

    test('submit is a no-op without a subject id', () async {
      final server = FakeServer();
      final form = FormConsent(
        propertyKey: testPropertyKey,
        subjectId: '',
        apiClient: ConsentIQApiClient(
          propertyKey: testPropertyKey,
          apiUrl: testApiUrl,
          client: server.client,
        ),
      );

      expect(await form.submit(), isNull);
      expect(server.requests, isEmpty);
    });

    test('reset clears the selection', () {
      final form = FormConsent(propertyKey: testPropertyKey, subjectId: 'u1');
      form.setChannel('email', true);

      form.reset();

      expect(form.consents.values.every((v) => v == false), isTrue);
    });
  });

  group('FormConsent identity pairing', () {
    test(
        'sends the signed identifier when the subject is it written '
        'differently', () async {
      final server = FakeServer();
      await FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'Alice@Example.com',
        identityToken: 'v2.1.sig',
        identityFor: 'alice@example.com',
        apiClient: ConsentIQApiClient(
            propertyKey: testPropertyKey,
            apiUrl: testApiUrl,
            client: server.client),
      ).submit();
      final post = server.submits.single.json;
      expect(post['subjectId'], 'alice@example.com');
      expect(post['identityToken'], 'v2.1.sig');
    });

    test('sends another subject unsigned', () async {
      final server = FakeServer();
      await FormConsent(
        propertyKey: testPropertyKey,
        subjectId: 'bob@example.com',
        identityToken: 'v2.1.sig',
        identityFor: 'alice@example.com',
        apiClient: ConsentIQApiClient(
            propertyKey: testPropertyKey,
            apiUrl: testApiUrl,
            client: server.client),
      ).submit();
      final post = server.submits.single.json;
      expect(post['subjectId'], 'bob@example.com');
      expect(post.containsKey('identityToken'), isFalse);
    });
  });
}
