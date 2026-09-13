import 'consent_state.dart';
import 'json.dart';

class PropertyInfo {
  const PropertyInfo({
    required this.id,
    required this.name,
    required this.identifier,
    required this.platform,
    this.defaultLanguage,
    this.supportedLanguages = const [],
  });

  factory PropertyInfo.fromJson(Map<String, dynamic> json) => PropertyInfo(
        id: asString(json['id']),
        name: asString(json['name']),
        identifier: asString(json['identifier']),
        platform: asString(json['platform']),
        defaultLanguage: asStringOrNull(json['defaultLanguage']),
        supportedLanguages: asStringList(json['supportedLanguages']),
      );

  final String id;
  final String name;
  final String identifier;

  /// `web`, `ios` or `android`.
  final String platform;
  final String? defaultLanguage;
  final List<String> supportedLanguages;
}

class BannerConfig {
  const BannerConfig({
    this.position = 'bottom',
    this.layout = 'banner',
    this.theme = 'dark',
    this.showLogo = false,
    this.logoUrl,
    this.primaryColor,
    this.cornerStyle,
    this.showCookieIcon = false,
    this.cookieIconUrl,
    this.overlay = false,
    this.noticeUrl,
  });

  factory BannerConfig.fromJson(Map<String, dynamic> json) => BannerConfig(
        position: asString(json['position'], 'bottom'),
        layout: asString(json['layout'], 'banner'),
        theme: asString(json['theme'], 'dark'),
        showLogo: asBool(json['showLogo']),
        logoUrl: asStringOrNull(json['logoUrl']),
        primaryColor: asStringOrNull(json['primaryColor']),
        cornerStyle: asStringOrNull(json['cornerStyle']),
        showCookieIcon: asBool(json['showCookieIcon']),
        cookieIconUrl: asStringOrNull(json['cookieIconUrl']),
        overlay: asBool(json['overlay']),
        noticeUrl: asStringOrNull(json['noticeUrl']),
      );

  final String position;
  final String layout;
  final String theme;
  final bool showLogo;
  final String? logoUrl;

  /// Hex color such as `#f97316`.
  final String? primaryColor;

  /// `rounded` or `square`.
  final String? cornerStyle;
  final bool showCookieIcon;
  final String? cookieIconUrl;
  final bool overlay;

  /// Absolute URL of the cookie notice this banner is bound to.
  final String? noticeUrl;
}

class CategoryInfo {
  const CategoryInfo({
    required this.code,
    this.enabled = true,
    this.defaultState = false,
    required this.name,
    this.description,
    this.isRequired = false,
  });

  factory CategoryInfo.fromJson(Map<String, dynamic> json) => CategoryInfo(
        code: asString(json['code']),
        enabled: asBool(json['enabled'], true),
        defaultState: asBool(json['defaultState']),
        name: asString(json['name'], asString(json['code'])),
        description: asStringOrNull(json['description']),
        isRequired: asBool(json['isRequired']),
      );

  final String code;
  final bool enabled;
  final bool defaultState;
  final String name;
  final String? description;
  final bool isRequired;
}

class MarketingChannelInfo {
  const MarketingChannelInfo({
    required this.code,
    required this.name,
    this.description,
    this.requiresDoubleOptin = false,
  });

  factory MarketingChannelInfo.fromJson(Map<String, dynamic> json) =>
      MarketingChannelInfo(
        code: asString(json['code']),
        name: asString(json['name'], asString(json['code'])),
        description: asStringOrNull(json['description']),
        requiresDoubleOptin: asBool(json['requiresDoubleOptin']),
      );

  final String code;
  final String name;
  final String? description;
  final bool requiresDoubleOptin;
}

class GeoRule {
  const GeoRule({
    required this.countries,
    required this.regulation,
    this.requireExplicitConsent = false,
  });

  factory GeoRule.fromJson(Map<String, dynamic> json) => GeoRule(
        countries: asStringList(json['countries']),
        regulation: asString(json['regulation']),
        requireExplicitConsent: asBool(json['requireExplicitConsent']),
      );

  final List<String> countries;
  final String regulation;
  final bool requireExplicitConsent;
}

class PrivacyNoticeInfo {
  const PrivacyNoticeInfo({
    required this.id,
    required this.name,
    this.contentTranslations = const {},
    required this.noticeType,
    this.version,
  });

  factory PrivacyNoticeInfo.fromJson(Map<String, dynamic> json) =>
      PrivacyNoticeInfo(
        id: asString(json['id']),
        name: asString(json['name']),
        contentTranslations: asMap(json['contentTranslations']),
        noticeType: asString(json['noticeType']),
        version: asIntOrNull(json['version']),
      );

  final String id;
  final String name;
  final Map<String, dynamic> contentTranslations;
  final String noticeType;
  final int? version;
}

class LinkedPrivacyNotice {
  const LinkedPrivacyNotice({
    required this.id,
    required this.name,
    required this.type,
  });

  factory LinkedPrivacyNotice.fromJson(Map<String, dynamic> json) =>
      LinkedPrivacyNotice(
        id: asString(json['id']),
        name: asString(json['name']),
        type: asString(json['type']),
      );

  final String id;
  final String name;
  final String type;
}

class FormConsentSource {
  const FormConsentSource({
    this.selector,
    this.isAutoResolved = false,
    required this.privacyNotice,
  });

  factory FormConsentSource.fromJson(Map<String, dynamic> json) =>
      FormConsentSource(
        selector: asStringOrNull(json['selector']),
        isAutoResolved: asBool(json['isAutoResolved']),
        privacyNotice:
            LinkedPrivacyNotice.fromJson(asMap(json['privacyNotice'])),
      );

  final String? selector;
  final bool isAutoResolved;
  final LinkedPrivacyNotice privacyNotice;
}

class CategoryTranslation {
  const CategoryTranslation({required this.title, required this.description});

  factory CategoryTranslation.fromJson(Map<String, dynamic> json) =>
      CategoryTranslation(
        title: asString(json['title']),
        description: asString(json['description']),
      );

  final String title;
  final String description;
}

class TranslationSet {
  const TranslationSet({this.bannerDescription, this.categories = const {}});

  factory TranslationSet.fromJson(Map<String, dynamic> json) => TranslationSet(
        bannerDescription: asStringOrNull(json['bannerDescription']),
        categories: asMap(json['categories']).map(
          (code, value) =>
              MapEntry(code, CategoryTranslation.fromJson(asMap(value))),
        ),
      );

  final String? bannerDescription;
  final Map<String, CategoryTranslation> categories;
}

/// System-owned sheet chrome for one language. Served by the API for every
/// language the property supports; nothing is bundled in the SDK.
class BannerLabels {
  const BannerLabels({
    this.title = '',
    this.acceptAll = '',
    this.acceptRequired = '',
    this.reject = '',
    this.customize = '',
    this.save = '',
    this.preferencesTitle = '',
    this.viewNotice = '',
  });

  factory BannerLabels.fromJson(Map<String, dynamic> json) => BannerLabels(
        title: asString(json['title']),
        acceptAll: asString(json['acceptAll']),
        acceptRequired: asString(json['acceptRequired']),
        reject: asString(json['reject']),
        customize: asString(json['customize']),
        save: asString(json['save']),
        preferencesTitle: asString(json['preferencesTitle']),
        viewNotice: asString(json['viewNotice']),
      );

  final String title;
  final String acceptAll;
  final String acceptRequired;
  final String reject;
  final String customize;
  final String save;
  final String preferencesTitle;
  final String viewNotice;
}

/// A property's configuration as served by `GET /api/public/config/{key}`.
class PropertyConfig {
  const PropertyConfig({
    required this.property,
    this.banner = const BannerConfig(),
    this.categories = const [],
    this.marketingChannels = const [],
    this.geoRules = const [],
    this.resolvedRegulation,
    this.privacyNotices = const [],
    this.formConsentSources = const [],
    this.privacyNoticeUrl,
    this.requireCaptcha = false,
    this.turnstileSiteKey,
    this.autoBlock = false,
    this.translations = const {},
    this.labels = const {},
    this.rtl = const [],
  });

  factory PropertyConfig.fromJson(Map<String, dynamic> json) => PropertyConfig(
        property: PropertyInfo.fromJson(asMap(json['property'])),
        banner: BannerConfig.fromJson(asMap(json['banner'])),
        categories: asMapList(json['categories'])
            .map(CategoryInfo.fromJson)
            .toList(growable: false),
        marketingChannels: asMapList(json['marketingChannels'])
            .map(MarketingChannelInfo.fromJson)
            .toList(growable: false),
        geoRules: asMapList(json['geoRules'])
            .map(GeoRule.fromJson)
            .toList(growable: false),
        resolvedRegulation: asStringOrNull(json['resolvedRegulation']),
        privacyNotices: asMapList(json['privacyNotices'])
            .map(PrivacyNoticeInfo.fromJson)
            .toList(growable: false),
        formConsentSources: asMapList(json['formConsentSources'])
            .map(FormConsentSource.fromJson)
            .toList(growable: false),
        privacyNoticeUrl: asStringOrNull(json['privacyNoticeUrl']),
        requireCaptcha: asBool(json['requireCaptcha']),
        turnstileSiteKey: asStringOrNull(json['turnstileSiteKey']),
        autoBlock: asBool(json['autoBlock']),
        translations: asMap(json['translations']).map(
          (lang, value) =>
              MapEntry(lang, TranslationSet.fromJson(asMap(value))),
        ),
        labels: asMap(json['labels']).map(
          (lang, value) => MapEntry(lang, BannerLabels.fromJson(asMap(value))),
        ),
        rtl: asStringList(json['rtl']),
      );

  final PropertyInfo property;
  final BannerConfig banner;
  final List<CategoryInfo> categories;
  final List<MarketingChannelInfo> marketingChannels;
  final List<GeoRule> geoRules;

  /// Server-resolved regulation for the caller, or null when none applies.
  final String? resolvedRegulation;
  final List<PrivacyNoticeInfo> privacyNotices;
  final List<FormConsentSource> formConsentSources;
  final String? privacyNoticeUrl;

  /// When true the server refuses every submit from this SDK; see the README.
  final bool requireCaptcha;
  final String? turnstileSiteKey;
  final bool autoBlock;
  final Map<String, TranslationSet> translations;
  final Map<String, BannerLabels> labels;

  /// Language codes that render right-to-left.
  final List<String> rtl;

  static String baseTag(String language) =>
      language.split('-').first.toLowerCase();

  /// `labels[lang]`, then the base tag, then English.
  BannerLabels labelsFor(String language) =>
      labels[language] ??
      labels[baseTag(language)] ??
      labels['en'] ??
      const BannerLabels();

  TranslationSet? translationsFor(String language) =>
      translations[language] ??
      translations[baseTag(language)] ??
      translations['en'];

  bool isRtl(String language) => rtl.contains(baseTag(language));
}

/// A stored consent as returned by `GET /api/public/consent/{key}/{subject}`.
class SavedConsent {
  const SavedConsent({
    required this.id,
    required this.cookieConsents,
    this.marketingConsents,
    required this.consentedAt,
    this.expiresAt,
    this.regulationApplied,
    this.consentVersion,
  });

  factory SavedConsent.fromJson(Map<String, dynamic> json) => SavedConsent(
        id: asString(json['id']),
        cookieConsents: consentStateFromJson(json['cookieConsents']) ??
            defaultConsentState(),
        marketingConsents: json['marketingConsents'] == null
            ? null
            : asBoolMap(json['marketingConsents']),
        consentedAt: asString(json['consentedAt']),
        expiresAt: asStringOrNull(json['expiresAt']),
        regulationApplied: asStringOrNull(json['regulationApplied']),
        consentVersion: asStringOrNull(json['consentVersion']),
      );

  final String id;
  final ConsentState cookieConsents;
  final MarketingConsentState? marketingConsents;
  final String consentedAt;
  final String? expiresAt;
  final String? regulationApplied;
  final String? consentVersion;
}

/// Result of a consent lookup. A null [consent] with [expired] true means the
/// server-side consent lapsed and any local copy must be discarded.
class ConsentLookup {
  const ConsentLookup({this.consent, this.expired = false});

  factory ConsentLookup.fromJson(Map<String, dynamic> json) => ConsentLookup(
        consent: json['consent'] is Map
            ? SavedConsent.fromJson(asMap(json['consent']))
            : null,
        expired: asBool(json['expired']),
      );

  final SavedConsent? consent;
  final bool expired;
}

class ConsentSubmission {
  const ConsentSubmission({
    required this.success,
    required this.consentId,
    required this.proofHash,
  });

  factory ConsentSubmission.fromJson(Map<String, dynamic> json) =>
      ConsentSubmission(
        success: asBool(json['success']),
        consentId: asString(json['consentId']),
        proofHash: asString(json['proofHash']),
      );

  final bool success;
  final String consentId;
  final String proofHash;
}

class ConsentVerification {
  const ConsentVerification({
    required this.verified,
    required this.id,
    required this.consentedAt,
    required this.proofHash,
  });

  factory ConsentVerification.fromJson(Map<String, dynamic> json) {
    final consent = asMap(json['consent']);
    return ConsentVerification(
      verified: asBool(json['verified']),
      id: asString(consent['id']),
      consentedAt: asString(consent['consentedAt']),
      proofHash: asString(consent['proofHash']),
    );
  }

  final bool verified;
  final String id;
  final String consentedAt;
  final String proofHash;
}
