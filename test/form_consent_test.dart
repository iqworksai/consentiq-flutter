import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('FormConsent', () {
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
}
