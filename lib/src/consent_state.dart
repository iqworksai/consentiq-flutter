import 'json.dart';

/// Cookie-category consent keyed by category code.
typedef ConsentState = Map<String, bool>;

/// Marketing-channel consent keyed by channel code.
typedef MarketingConsentState = Map<String, bool>;

const String necessaryCategory = 'necessary';

const List<String> defaultConsentCategories = [
  necessaryCategory,
  'analytics',
  'marketing',
  'preferences',
  'social',
];

ConsentState defaultConsentState() => {
      for (final code in defaultConsentCategories)
        code: code == necessaryCategory,
    };

/// Copies [state] with `necessary` forced on.
ConsentState normalizeConsentState(Map<String, bool> state) => {
      ...state,
      necessaryCategory: true,
    };

/// Reads a consent map from decoded JSON, keeping only boolean values and
/// forcing `necessary` on. Returns null when nothing usable is present.
ConsentState? consentStateFromJson(Object? json) {
  final parsed = asBoolMap(json);
  if (parsed.isEmpty) return null;
  return normalizeConsentState(parsed);
}
