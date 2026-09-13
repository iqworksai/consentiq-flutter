import 'dart:convert';

import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  group('ConsentIQApiClient', () {
    test('getConfig hits the config URL and parses the payload', () async {
      final server = FakeServer();
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: '$testApiUrl/',
        client: server.client,
      );

      final config = await client.getConfig();

      expect(server.requests, hasLength(1));
      expect(server.requests.single.method, 'GET');
      expect(
        server.requests.single.url,
        '$testApiUrl/api/public/config/$testPropertyKey',
      );
      expect(
        server.requests.single.request.headers['Content-Type'],
        startsWith('application/json'),
      );
      expect(config.property.platform, 'ios');
      expect(config.resolvedRegulation, 'DPDPA');
      expect(config.categories.map((c) => c.code), [
        'necessary',
        'analytics',
        'marketing',
      ]);
      expect(config.categories.first.isRequired, isTrue);
      expect(config.banner.primaryColor, '#123456');
      expect(config.labelsFor('ar').acceptAll, 'قبول الكل');
      expect(config.labelsFor('ar-EG').acceptAll, 'قبول الكل');
      expect(config.labelsFor('fr').acceptAll, 'Accept all');
      expect(config.isRtl('ar-EG'), isTrue);
      expect(config.isRtl('en'), isFalse);
      expect(config.translationsFor('en')?.categories['analytics']?.title,
          'Analytics cookies');
    });

    test('models tolerate missing and extra keys', () {
      final config = PropertyConfig.fromJson({
        'property': {'id': 'p'},
        'banner': {'position': 'bottom', 'theme': 'dark', 'layout': 'banner'},
        'categories': [
          {'code': 'analytics', 'unexpected': 1},
        ],
        'resolvedRegulation': null,
        'unknownTopLevel': [1, 2, 3],
      });

      expect(config.property.defaultLanguage, isNull);
      expect(config.property.supportedLanguages, isEmpty);
      expect(config.banner.noticeUrl, isNull);
      expect(config.banner.cornerStyle, isNull);
      expect(config.banner.overlay, isFalse);
      expect(config.categories.single.name, 'analytics');
      expect(config.categories.single.enabled, isTrue);
      expect(config.resolvedRegulation, isNull);
      expect(config.requireCaptcha, isFalse);
      expect(config.labelsFor('en').title, '');
      expect(config.translationsFor('en'), isNull);

      final saved = SavedConsent.fromJson({
        'id': 'c',
        'cookieConsents': {'necessary': false, 'analytics': 'yes'},
        'consentedAt': 'now',
      });
      expect(saved.cookieConsents, {'necessary': true});
      expect(saved.marketingConsents, isNull);
      expect(saved.expiresAt, isNull);
      expect(saved.regulationApplied, isNull);
    });

    test('getConsent returns the consent and passes expired through', () async {
      final server = FakeServer(consent: savedConsentJson());
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      );

      final lookup = await client.getConsent('subject-1');

      expect(
        server.requests.single.url,
        '$testApiUrl/api/public/consent/$testPropertyKey/subject-1',
      );
      expect(lookup.expired, isFalse);
      expect(lookup.consent?.id, 'consent-1');
      expect(lookup.consent?.cookieConsents['analytics'], isTrue);
      expect(lookup.consent?.marketingConsents?['email'], isTrue);
    });

    test('getConsent reports expired with a null consent', () async {
      final server = FakeServer(
        consent: const {'consent': null, 'expired': true},
      );
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      );

      final lookup = await client.getConsent('subject-1');

      expect(lookup.consent, isNull);
      expect(lookup.expired, isTrue);
    });

    test('getConsent treats a missing expired flag as never given', () async {
      final server = FakeServer(consent: const {'consent': null});
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      );

      final lookup = await client.getConsent('subject-1');

      expect(lookup.consent, isNull);
      expect(lookup.expired, isFalse);
    });

    test('submitConsent posts the documented body and omits null fields',
        () async {
      final server = FakeServer();
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      );

      final result = await client.submitConsent(
        subjectId: 'subject-1',
        cookieConsents: const {'necessary': true, 'analytics': true},
        marketingConsents: const {'email': false},
      );

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.url, '$testApiUrl/api/public/consent');
      expect(
        request.request.headers['Content-Type'],
        startsWith('application/json'),
      );
      expect(request.json, {
        'propertyKey': testPropertyKey,
        'subjectId': 'subject-1',
        'cookieConsents': {'necessary': true, 'analytics': true},
        'marketingConsents': {'email': false},
        'consentMethod': 'sdk',
      });
      expect(result.success, isTrue);
      expect(result.consentId, 'c-1');
      expect(result.proofHash, 'hash');
    });

    test('submitConsent carries subjectType and form method', () async {
      final server = FakeServer();
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: server.client,
      );

      await client.submitConsent(
        subjectId: 'user-9',
        subjectType: 'user',
        marketingConsents: const {'email': true, 'sms': false},
        consentMethod: 'form',
        consentVersion: 'v2',
      );

      expect(server.requests.single.json, {
        'propertyKey': testPropertyKey,
        'subjectId': 'user-9',
        'subjectType': 'user',
        'marketingConsents': {'email': true, 'sms': false},
        'consentMethod': 'form',
        'consentVersion': 'v2',
      });
    });

    test('verifyConsent hits the verify URL', () async {
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: MockClient((request) async {
          expect(request.url.toString(), '$testApiUrl/api/public/verify/c-1');
          return http.Response(
            jsonEncode({
              'verified': true,
              'consent': {'id': 'c-1', 'consentedAt': 't', 'proofHash': 'h'},
            }),
            200,
          );
        }),
      );

      final verification = await client.verifyConsent('c-1');

      expect(verification.verified, isTrue);
      expect(verification.id, 'c-1');
      expect(verification.proofHash, 'h');
    });

    test('surfaces the server error message on 4xx', () async {
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: MockClient(
          (_) async => http.Response('{"error":"Property not found"}', 404),
        ),
      );

      expect(
        client.getConfig(),
        throwsA(
          isA<ConsentIQApiException>()
              .having((e) => e.message, 'message', 'Property not found')
              .having((e) => e.statusCode, 'statusCode', 404),
        ),
      );
    });

    test('falls back to HTTP status when the error body is not JSON', () async {
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: MockClient((_) async => http.Response('<html>', 503)),
      );

      expect(
        client.getConsent('s'),
        throwsA(
          isA<ConsentIQApiException>()
              .having((e) => e.message, 'message', 'HTTP 503')
              .having((e) => e.statusCode, 'statusCode', 503),
        ),
      );
    });

    test('captcha refusal on submit surfaces the server message', () async {
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: MockClient(
          (_) async => http.Response(
            '{"error":"Captcha verification failed. Please try again."}',
            400,
          ),
        ),
      );

      expect(
        client.submitConsent(
          subjectId: 's',
          cookieConsents: const {'necessary': true},
        ),
        throwsA(
          isA<ConsentIQApiException>().having(
            (e) => e.message,
            'message',
            'Captcha verification failed. Please try again.',
          ),
        ),
      );
    });
  });
}
