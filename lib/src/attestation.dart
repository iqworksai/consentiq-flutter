import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String attestChannel = 'ai.iqworks.consentiq/attest';
const String attestKeyHeader = 'X-ConsentIQ-Attest-Key';
const String assertionHeader = 'X-ConsentIQ-Assertion';
const String integrityHeader = 'X-ConsentIQ-Integrity';

/// The ConsentIQ calls registration needs: a single-use challenge, and the
/// key's registration, true when ConsentIQ answers 204.
abstract class AttestationServer {
  Future<Uint8List> appAttestChallenge();
  Future<bool> registerAppAttestKey(
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
    required this.propertyKey,
    this.playIntegrityCloudProjectNumber,
    MethodChannel channel = const MethodChannel(attestChannel),
  }) : _channel = channel;

  final AttestationServer server;
  final String propertyKey;
  final int? playIntegrityCloudProjectNumber;
  final MethodChannel _channel;
  Future<String?>? _registering;
  bool _gaveUpThisLaunch = false;

  String get _storageKey => 'consentiq_app_attest_key_$propertyKey';

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
    }
  }

  Future<Map<String, String>> _playIntegrity(String body) async {
    final project = playIntegrityCloudProjectNumber;
    if (project == null) return const {};
    final token = await _channel.invokeMethod<String>('playIntegrityToken', {
      'cloudProjectNumber': project,
      'body': body,
    });
    return token == null || token.isEmpty ? const {} : {integrityHeader: token};
  }

  Future<Map<String, String>> _appAttest(String body) async {
    if (await _channel.invokeMethod<bool>('appAttestSupported') != true) {
      return const {};
    }
    final keyId = await _registeredKey();
    if (keyId == null) return const {};
    try {
      final assertion = await _channel.invokeMethod<Uint8List>(
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
      final keyId = await _channel.invokeMethod<String>('appAttestGenerateKey');
      if (keyId == null) return null;
      final challenge = await server.appAttestChallenge();
      final attestation = await _channel.invokeMethod<Uint8List>(
        'appAttestKey',
        {'keyId': keyId, 'clientData': challenge},
      );
      if (attestation == null) return null;
      return await server.registerAppAttestKey(keyId, attestation, challenge)
          ? keyId
          : null;
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
