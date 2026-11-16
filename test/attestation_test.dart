import 'dart:async';
import 'dart:convert';

import 'package:consentiq/consentiq.dart';
import 'package:consentiq/src/attestation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class FakeServer implements AttestationServer {
  FakeServer({this.registers = true, this.status});

  final bool registers;
  final int? status;
  final Uint8List challenge = Uint8List.fromList([1, 2, 3, 250]);
  int challenges = 0;
  final List<String> registered = [];

  @override
  Future<Uint8List> appAttestChallenge() async {
    challenges++;
    return challenge;
  }

  @override
  Future<int> registerAppAttestKey(
    String keyId,
    Uint8List attestation,
    Uint8List challenge,
  ) async {
    registered.add(keyId);
    return status ?? (registers ? 204 : 403);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(attestChannel);
  late List<MethodCall> calls;
  var supported = true;
  var keyId = 'key-1';
  Object? assertionError;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    supported = true;
    keyId = 'key-1';
    assertionError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'appAttestSupported':
          return supported;
        case 'appAttestGenerateKey':
          return keyId;
        case 'appAttestKey':
          return Uint8List.fromList(utf8.encode('attestation'));
        case 'appAttestAssertion':
          if (assertionError != null) throw assertionError!;
          return Uint8List.fromList(utf8.encode('assertion'));
        case 'playIntegrityToken':
          return 'integrity-token';
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  var now = DateTime.fromMillisecondsSinceEpoch(1800000000000);

  AppAttestation attestation(
    FakeServer server, {
    int? project,
    String apiUrl = testApiUrl,
  }) =>
      AppAttestation(
        server: server,
        apiUrl: apiUrl,
        propertyKey: testPropertyKey,
        playIntegrityCloudProjectNumber: project,
        clock: () => now,
      );

  group('iOS App Attest', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('registers once, then signs each body', () async {
      final server = FakeServer();
      final attestor = attestation(server);

      final headers = await attestor.headers('{"a":1}');
      await attestor.headers('{"a":2}');

      expect(headers, {
        'X-ConsentIQ-Attest-Key': 'key-1',
        'X-ConsentIQ-Assertion': base64Encode(utf8.encode('assertion')),
      });
      expect(server.challenges, 1);
      expect(server.registered, ['key-1']);
      final attest = calls.firstWhere((c) => c.method == 'appAttestKey');
      expect((attest.arguments as Map)['clientData'], server.challenge);
      final assertions =
          calls.where((c) => c.method == 'appAttestAssertion').toList();
      expect(
        assertions.map((c) =>
            utf8.decode((c.arguments as Map)['clientData'] as Uint8List)),
        ['{"a":1}', '{"a":2}'],
      );
    });

    test('a registered key survives a relaunch', () async {
      final server = FakeServer();
      await attestation(server).headers('x');
      final relaunched = await attestation(server).headers('x');

      expect(relaunched['X-ConsentIQ-Attest-Key'], 'key-1');
      expect(server.registered, hasLength(1));
    });

    test('unsupported devices send nothing', () async {
      supported = false;
      final server = FakeServer();

      expect(await attestation(server).headers('x'), isEmpty);
      expect(server.challenges, 0);
    });

    test('a refused registration sends nothing until the next launch',
        () async {
      final refusing = FakeServer(registers: false);
      final attestor = attestation(refusing);

      expect(await attestor.headers('x'), isEmpty);
      expect(await attestor.headers('x'), isEmpty);
      expect(refusing.registered, hasLength(1));

      final next = FakeServer();
      expect(
        (await attestation(next).headers('x'))['X-ConsentIQ-Attest-Key'],
        'key-1',
      );
    });

    test('a key the system refuses is replaced on the next launch', () async {
      final server = FakeServer();
      await attestation(server).headers('x');
      assertionError = PlatformException(code: 'app_attest');

      expect(await attestation(server).headers('x'), isEmpty);

      assertionError = null;
      keyId = 'key-2';
      expect(
        (await attestation(server).headers('x'))['X-ConsentIQ-Attest-Key'],
        'key-2',
      );
    });

    test('the challenge is passed on as its decoded bytes', () async {
      // The contract's vector: challenge "AQID-g" is the bytes 01 02 03 FA,
      // and the platform code hashes those bytes, never the base64url text.
      final server = FakeServer();
      await attestation(server).headers('x');

      final attest = calls.firstWhere((c) => c.method == 'appAttestKey');
      expect((attest.arguments as Map)['clientData'], [1, 2, 3, 250]);
      expect(decodeBase64Url('AQID-g'), [1, 2, 3, 250]);
    });

    test('a key belongs to one server', () async {
      final server = FakeServer();
      await attestation(server).headers('x');
      keyId = 'key-2';

      final production = await attestation(
        server,
        apiUrl: 'https://prod.example.test',
      ).headers('x');

      expect(production['X-ConsentIQ-Attest-Key'], 'key-2');
      expect(server.registered, hasLength(2));
    });

    test('an unconfigured app waits days before registering again', () async {
      final unconfigured = FakeServer(status: 409);
      await attestation(unconfigured).headers('x');

      now = now.add(const Duration(days: 1));
      final next = FakeServer();
      expect(await attestation(next).headers('x'), isEmpty);
      expect(next.registered, isEmpty);

      now = now.add(const Duration(days: 3));
      expect(
        (await attestation(next).headers('x'))['X-ConsentIQ-Attest-Key'],
        'key-1',
      );
    });

    test('a key challenged three times in a row is registered again', () async {
      final server = FakeServer();
      final attestor = attestation(server);
      await attestor.headers('x');

      await attestor.attestedRequestWasChallenged();
      await attestor.attestedRequestWasChallenged();
      attestor.attestedRequestWasAccepted();
      await attestor.attestedRequestWasChallenged();
      await attestor.attestedRequestWasChallenged();
      await attestation(server).headers('x');
      expect(server.registered, hasLength(1),
          reason: 'an acceptance resets the count');

      await attestor.attestedRequestWasChallenged();
      keyId = 'key-2';
      final replaced = await attestation(server).headers('x');
      expect(replaced['X-ConsentIQ-Attest-Key'], 'key-2');
      expect(server.registered, hasLength(2));
    });

    test('a platform call that never answers sends nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel, (call) => Completer<Object?>().future);

      await expectLater(
        attestation(FakeServer()).headers('x'),
        completion(isEmpty),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a missing platform implementation sends nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);

      expect(await attestation(FakeServer()).headers('x'), isEmpty);
    });
  });

  group('Android Play Integrity', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('sends a token over the exact body with a cloud project number',
        () async {
      final headers =
          await attestation(FakeServer(), project: 1234).headers('{"a":1}');

      expect(headers, {'X-ConsentIQ-Integrity': 'integrity-token'});
      expect(calls.single.method, 'playIntegrityToken');
      expect(calls.single.arguments,
          {'cloudProjectNumber': 1234, 'body': '{"a":1}'});
    });

    test('without a cloud project number sends nothing', () async {
      expect(await attestation(FakeServer()).headers('x'), isEmpty);
      expect(calls, isEmpty);
    });

    test('a Play Integrity call that never answers sends nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              channel, (call) => Completer<Object?>().future);

      await expectLater(
        attestation(FakeServer(), project: 1).headers('x'),
        completion(isEmpty),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a failed check sends nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'play_integrity');
      });

      expect(await attestation(FakeServer(), project: 1).headers('x'), isEmpty);
    });
  });

  group('the API client', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('signs the body it sends, and talks to the attestation endpoints',
        () async {
      final requests = <http.Request>[];
      final client = ConsentIQApiClient(
        propertyKey: testPropertyKey,
        apiUrl: testApiUrl,
        client: MockClient((request) async {
          requests.add(request);
          switch (request.url.path) {
            case '/api/public/app-attest/challenge':
              return http.Response('{"challenge":"AQID-g"}', 200);
            case '/api/public/app-attest/register':
              return http.Response('', 204);
          }
          return http.Response(
              '{"success":true,"consentId":"c-1","proofHash":"h"}', 200);
        }),
      );
      client.attestation = AppAttestation(
        server: client,
        apiUrl: testApiUrl,
        propertyKey: testPropertyKey,
        playIntegrityCloudProjectNumber: 1,
      );

      await client.submitConsent(subjectId: 's', cookieConsents: {});
      expect(
          requests.single.headers['X-ConsentIQ-Integrity'], 'integrity-token');
      expect((calls.single.arguments as Map)['body'], requests.single.body);

      expect(await client.appAttestChallenge(), [1, 2, 3, 250]);
      expect(
        await client.registerAppAttestKey(
          'key-1',
          Uint8List.fromList([9]),
          Uint8List.fromList([1, 2, 3, 250]),
        ),
        204,
      );
      final register = jsonDecode(requests.last.body) as Map;
      expect(register, {
        'propertyKey': testPropertyKey,
        'keyId': 'key-1',
        'attestation': 'CQ==',
        'challenge': 'AQID-g',
      });
    });
  });
}
