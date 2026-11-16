import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String attestChannel = 'ai.iqworks.consentiq/attest';
const String attestKeyHeader = 'X-ConsentIQ-Attest-Key';
const String assertionHeader = 'X-ConsentIQ-Assertion';
const String integrityHeader = 'X-ConsentIQ-Integrity';

/// How long a platform attestation call may take before the submission goes
/// without it and ConsentIQ asks for a captcha instead.
const Duration attestationCallTimeout = Duration(seconds: 10);

/// After a 409 (the property has no app identifiers yet) registration waits
/// this long.
const Duration attestNotConfiguredBackoff = Duration(days: 3);

/// Attested requests challenged in a row before the key is treated as unknown
/// to the server.
const int attestChallengesBeforeReregistering = 3;

/// The ConsentIQ calls registration needs: a single-use challenge, and the
/// key's registration, answering with the HTTP status (204 registered it).
abstract class AttestationServer {
  Future<Uint8List> appAttestChallenge();
  Future<int> registerAppAttestKey(
    String keyId,
    Uint8List attestation,
    Uint8List challenge,
  );
}

/// Proves a submission comes from this app: Apple's App Attest on iOS, Play
/// Integrity on Android. Each call signs the exact body that is sent. Where
/// the check cannot run (a simulator, no Play services, an older device, no
/// cloud project number), it returns no headers and ConsentIQ asks for a
/// captcha instead.
///
/// The hashing happens in the platform code, so the bytes hashed are the
/// bytes the platform's attestation API signs.
class AppAttestation {
  AppAttestation({
    required this.server,
    required this.apiUrl,
    required this.propertyKey,
    this.playIntegrityCloudProjectNumber,
    MethodChannel channel = const MethodChannel(attestChannel),
    DateTime Function()? clock,
  })  : _channel = channel,
        _clock = clock ?? DateTime.now;

  final AttestationServer server;
  final String apiUrl;
  final String propertyKey;
  final int? playIntegrityCloudProjectNumber;
  final MethodChannel _channel;
  final DateTime Function() _clock;
  Future<String?>? _registering;
  bool _gaveUpThisLaunch = false;
  int _challengedInARow = 0;

  // A key belongs to one server and property: one registered on staging means
  // nothing to production.
  String get _scope => '$apiUrl|$propertyKey';
  String get _storageKey => 'consentiq_app_attest_key_$_scope';
  String get _backoffKey => 'consentiq_app_attest_backoff_$_scope';

  void attestedRequestWasAccepted() => _challengedInARow = 0;

  Future<void> attestedRequestWasChallenged() async {
    _challengedInARow++;
    if (_challengedInARow < attestChallengesBeforeReregistering) return;
    _challengedInARow = 0;
    await (await SharedPreferences.getInstance()).remove(_storageKey);
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) => _channel
      .invokeMethod<T>(method, arguments)
      .timeout(attestationCallTimeout, onTimeout: () => null);

  Future<Map<String, String>> headers(String body) async {
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS:
          return await _appAttest(body);
        case TargetPlatform.android:
          return await _playIntegrity(body);
        default:
          return const {};
      }
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    } on TimeoutException {
      return const {};
    }
  }

  Future<Map<String, String>> _playIntegrity(String body) async {
    final project = playIntegrityCloudProjectNumber;
    if (project == null) return const {};
    final token = await _invoke<String>('playIntegrityToken', {
      'cloudProjectNumber': project,
      'body': body,
    });
    return token == null || token.isEmpty ? const {} : {integrityHeader: token};
  }

  Future<Map<String, String>> _appAttest(String body) async {
    if (await _invoke<bool>('appAttestSupported') != true) {
      return const {};
    }
    final keyId = await _registeredKey();
    if (keyId == null) return const {};
    try {
      final assertion = await _invoke<Uint8List>(
        'appAttestAssertion',
        {'keyId': keyId, 'clientData': Uint8List.fromList(utf8.encode(body))},
      );
      if (assertion == null) return const {};
      return {
        attestKeyHeader: keyId,
        assertionHeader: base64Encode(assertion),
      };
    } on PlatformException {
      // A key the system no longer recognizes is replaced on the next launch.
      await (await SharedPreferences.getInstance()).remove(_storageKey);
      _gaveUpThisLaunch = true;
      return const {};
    }
  }

  Future<String?> _registeredKey() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_storageKey);
    if (stored != null) return stored;
    if (_gaveUpThisLaunch) return null;
    final until = prefs.getInt(_backoffKey);
    if (until != null && _clock().millisecondsSinceEpoch < until) return null;
    final keyId = await (_registering ??= _registerNewKey());
    _registering = null;
    if (keyId == null) {
      _gaveUpThisLaunch = true;
    } else {
      await prefs.setString(_storageKey, keyId);
    }
    return keyId;
  }

  Future<String?> _registerNewKey() async {
    try {
      final keyId = await _invoke<String>('appAttestGenerateKey');
      if (keyId == null) return null;
      final challenge = await server.appAttestChallenge();
      final attestation = await _invoke<Uint8List>(
        'appAttestKey',
        {'keyId': keyId, 'clientData': challenge},
      );
      if (attestation == null) return null;
      final status =
          await server.registerAppAttestKey(keyId, attestation, challenge);
      final prefs = await SharedPreferences.getInstance();
      if (status == 204) {
        await prefs.remove(_backoffKey);
        return keyId;
      }
      if (status == 409) {
        await prefs.setInt(
          _backoffKey,
          _clock().add(attestNotConfiguredBackoff).millisecondsSinceEpoch,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// base64url as the server sends its challenge, decoded to raw bytes.
Uint8List decodeBase64Url(String value) =>
    base64Url.decode(base64Url.normalize(value));

/// base64url without padding, as the server reads it back.
String encodeBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
