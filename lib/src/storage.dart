import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'consent_state.dart';

class ConsentStorage {
  ConsentStorage({SharedPreferences? preferences}) : _preferences = preferences;

  static const String consentKey = 'consentiq_consent';
  static const String subjectIdKey = 'consentiq_subject_id';

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

  Future<void> clearConsent() async {
    try {
      await (await _prefs()).remove(consentKey);
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

  /// Removes the consent cache and the subject id.
  Future<void> clearAll() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(consentKey);
      await prefs.remove(subjectIdKey);
    } catch (_) {}
  }
}
