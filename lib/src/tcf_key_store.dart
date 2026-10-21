import 'package:flutter/services.dart';

const String tcfKeyChannel = 'ai.iqworks.consentiq/iabtcf';
const String tcfKeyPrefix = 'IABTCF_';
const String tcfRestrictionsKeyPrefix = 'IABTCF_PublisherRestrictions';
const int tcfMaxPurposeId = 11;

const List<String> tcfCmpKeys = ['IABTCF_CmpSdkID', 'IABTCF_CmpSdkVersion'];

/// Every key a decision writes, except the CMP's own identity and
/// `IABTCF_gdprApplies`, which outlive any one decision.
final List<String> tcfDecisionKeys = List.unmodifiable([
  'IABTCF_PolicyVersion',
  'IABTCF_PublisherCC',
  'IABTCF_PurposeOneTreatment',
  'IABTCF_UseNonStandardTexts',
  'IABTCF_TCString',
  'IABTCF_VendorConsents',
  'IABTCF_VendorLegitimateInterests',
  'IABTCF_DisclosedVendors',
  'IABTCF_PurposeConsents',
  'IABTCF_PurposeLegitimateInterests',
  'IABTCF_SpecialFeaturesOptIns',
  'IABTCF_PublisherConsent',
  'IABTCF_PublisherLegitimateInterests',
  'IABTCF_PublisherCustomPurposesConsents',
  'IABTCF_PublisherCustomPurposesLegitimateInterests',
  for (var id = 1; id <= tcfMaxPurposeId; id++) '$tcfRestrictionsKeyPrefix$id',
]);

/// Writes the `IABTCF_*` keys where IAB vendors' SDKs read them: Android's
/// default SharedPreferences and iOS `UserDefaults.standard`.
///
/// It goes through the SDK's own platform code because `shared_preferences`
/// writes integers as Android longs and prefixes every key.
class TcfKeyStore {
  const TcfKeyStore(
      {MethodChannel channel = const MethodChannel(tcfKeyChannel)})
      : _channel = channel;

  final MethodChannel _channel;

  /// Writes every `IABTCF_*` entry of [keys], numbers as integers and strings
  /// as strings, and removes each decision key [keys] does not carry. The CMP
  /// keys are left to [writeCmp].
  Future<void> write(Map<String, Object?> keys) {
    final ints = <String, int>{};
    final strings = <String, String>{};
    keys.forEach((key, value) {
      if (!key.startsWith(tcfKeyPrefix) || tcfCmpKeys.contains(key)) return;
      if (value is String) {
        strings[key] = value;
      } else if (value is num) {
        ints[key] = value.toInt();
      } else if (value is bool) {
        ints[key] = value ? 1 : 0;
      }
    });
    final remove = [
      for (final key in tcfDecisionKeys)
        if (!ints.containsKey(key) && !strings.containsKey(key)) key,
    ];
    return _update(ints: ints, strings: strings, remove: remove);
  }

  /// Removes the last decision, so vendors stop reading it.
  Future<void> clearDecision() => _update(remove: tcfDecisionKeys);

  /// Removes every key this SDK writes, for when the property leaves TCF.
  Future<void> clearAll() => _update(remove: [
        ...tcfDecisionKeys,
        ...tcfCmpKeys,
        'IABTCF_gdprApplies',
      ]);

  Future<void> writeGdprApplies(bool applies) =>
      _update(ints: {'IABTCF_gdprApplies': applies ? 1 : 0});

  Future<void> writeCmp({required int cmpId, required int cmpVersion}) =>
      _update(ints: {
        'IABTCF_CmpSdkID': cmpId,
        'IABTCF_CmpSdkVersion': cmpVersion,
      });

  Future<void> _update({
    Map<String, int> ints = const {},
    Map<String, String> strings = const {},
    List<String> remove = const [],
  }) =>
      _channel.invokeMethod<void>('update', {
        'ints': ints,
        'strings': strings,
        'remove': remove,
      });
}
