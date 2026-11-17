import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'consent_state.dart';
import 'json.dart';
import 'pending.dart';

class ConsentStorage {
  ConsentStorage({SharedPreferences? preferences}) : _preferences = preferences;

  static const String consentKey = 'consentiq_consent';
  static const String subjectIdKey = 'consentiq_subject_id';
  static const String tcfKey = 'consentiq_tcf';
  static const String tcfCmpKey = 'consentiq_tcf_cmp';
  static const String pendingKey = 'consentiq_pending';

  /// The subject the local copy was written for.
  static const String consentSubjectKey = 'consentiq_consent_subject';

  /// Set to the property key when a decision was dropped without ConsentIQ
  /// recording it. While it stands the sheet asks again with nothing granted.
  /// The next recorded decision clears it.
  static const String unrecordedKey = 'consentiq_unrecorded_decision';

  SharedPreferences? _preferences;

  static String generateSubjectId() => const Uuid().v4();

  Future<SharedPreferences> _prefs() async =>
      _preferences ??= await SharedPreferences.getInstance();

  Future<ConsentState?> loadConsent() async {
    try {
      final raw = (await _prefs()).getString(consentKey);
      if (raw == null) return null;
      return consentStateFromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveConsent(ConsentState consent) async {
    try {
      await (await _prefs()).setString(
        consentKey,
        jsonEncode(normalizeConsentState(consent)),
      );
    } catch (_) {}
  }

  /// The local copy, only when it was written for [subjectId]: another subject
  /// never inherits it.
  Future<ConsentState?> loadConsentFor(String subjectId) async {
    try {
      if ((await _prefs()).getString(consentSubjectKey) != subjectId) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return loadConsent();
  }

  Future<void> saveConsentFor(ConsentState consent, String subjectId) async {
    await saveConsent(consent);
    try {
      await (await _prefs()).setString(consentSubjectKey, subjectId);
    } catch (_) {}
  }

  Future<void> clearConsent() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(consentKey);
      await prefs.remove(consentSubjectKey);
    } catch (_) {}
  }

  Future<bool> isUnrecorded(String propertyKey) async {
    try {
      return (await _prefs()).getString(unrecordedKey) == propertyKey;
    } catch (_) {
      return false;
    }
  }

  Future<void> markUnrecorded(String propertyKey) async {
    try {
      await (await _prefs()).setString(unrecordedKey, propertyKey);
    } catch (_) {}
  }

  Future<void> clearUnrecorded() async {
    try {
      await (await _prefs()).remove(unrecordedKey);
    } catch (_) {}
  }

  Future<String?> loadSubjectId() async {
    try {
      return (await _prefs()).getString(subjectIdKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSubjectId(String subjectId) async {
    try {
      await (await _prefs()).setString(subjectIdKey, subjectId);
    } catch (_) {}
  }

  Future<String> getOrCreateSubjectId() async {
    final existing = await loadSubjectId();
    if (existing != null && existing.isNotEmpty) return existing;
    final created = generateSubjectId();
    await saveSubjectId(created);
    return created;
  }

  /// The last IAB TCF decision's `stored` record, kept as the hosted page
  /// sent it.
  Future<Map<String, dynamic>?> loadTcf() async {
    try {
      final raw = (await _prefs()).getString(tcfKey);
      if (raw == null) return null;
      final stored = asMap(jsonDecode(raw));
      return stored.isEmpty ? null : stored;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTcf(Map<String, dynamic> stored) async {
    try {
      await (await _prefs()).setString(tcfKey, jsonEncode(stored));
    } catch (_) {}
  }

  Future<void> clearTcf() async {
    try {
      await (await _prefs()).remove(tcfKey);
    } catch (_) {}
  }

  /// Whether this SDK has written the CMP keys in this install, and so owns
  /// the `IABTCF_*` keys. It survives [clearAll].
  Future<bool> loadTcfCmpWritten() async {
    try {
      return (await _prefs()).getBool(tcfCmpKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveTcfCmpWritten() async {
    try {
      await (await _prefs()).setBool(tcfCmpKey, true);
    } catch (_) {}
  }

  Future<void> clearTcfCmpWritten() async {
    try {
      await (await _prefs()).remove(tcfCmpKey);
    } catch (_) {}
  }

  Future<PendingDecision?> loadPending() async {
    try {
      final raw = (await _prefs()).getString(pendingKey);
      if (raw == null) return null;
      final pending = PendingDecision.fromJson(jsonDecode(raw));
      if (pending == null) await clearPending();
      return pending;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePending(PendingDecision pending) async {
    try {
      await (await _prefs())
          .setString(pendingKey, jsonEncode(pending.toJson()));
    } catch (_) {}
  }

  Future<void> clearPending() async {
    try {
      await (await _prefs()).remove(pendingKey);
    } catch (_) {}
  }

  /// Removes the consent cache, the TCF record, the subject id, any decision
  /// waiting to be resent and the unrecorded marker.
  Future<void> clearAll() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(consentKey);
      await prefs.remove(consentSubjectKey);
      await prefs.remove(tcfKey);
      await prefs.remove(subjectIdKey);
      await prefs.remove(pendingKey);
      await prefs.remove(unrecordedKey);
    } catch (_) {}
  }
}
