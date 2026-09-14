import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'config.dart';
import 'consent_state.dart';
import 'log.dart';
import 'models.dart';
import 'storage.dart';

const String captchaWarning =
    'This property requires a captcha, which mobile SDKs cannot satisfy. '
    'Turn off "Require captcha" for this property in the ConsentIQ dashboard.';

/// The consent state machine. Create one per app, call [init] once, and read
/// it through [ConsentIQProvider] or listen to it directly.
class ConsentIQ extends ChangeNotifier {
  ConsentIQ(this.options,
      {ConsentIQApiClient? apiClient, ConsentStorage? storage})
      : _api = apiClient ??
            ConsentIQApiClient(
              propertyKey: options.propertyKey,
              apiUrl: options.apiUrl,
              debug: options.debug,
            ),
        _ownsApi = apiClient == null,
        _storage = storage ?? ConsentStorage(),
        _logger = ConsentIQLogger(debug: options.debug),
        _language = options.language ?? 'en';

  final ConsentIQConfig options;
  final ConsentIQApiClient _api;
  final bool _ownsApi;
  final ConsentStorage _storage;
  final ConsentIQLogger _logger;

  ConsentState _consent = defaultConsentState();
  MarketingConsentState _marketingConsent = {};
  PropertyConfig? _config;
  bool _isLoading = true;
  bool _isSheetVisible = false;
  String _language;
  String? _regulation;
  String? _subjectId;
  Future<void>? _initFuture;
  bool _disposed = false;

  ConsentState get consent => Map.unmodifiable(_consent);
  MarketingConsentState get marketingConsent =>
      Map.unmodifiable(_marketingConsent);
  PropertyConfig? get config => _config;
  bool get isLoading => _isLoading;
  bool get isSheetVisible => _isSheetVisible;
  String get language => _language;
  String? get regulation => _regulation;
  String? get subjectId => _subjectId;

  bool get isRtl => _config?.isRtl(_language) ?? false;
  BannerLabels? get labels => _config?.labelsFor(_language);
  TranslationSet? get translations => _config?.translationsFor(_language);

  /// Loads the property config and any recorded consent. Safe to call without
  /// awaiting; it never throws and runs only once.
  Future<void> init() => _initFuture ??= _initialize();

  Future<void> _initialize() async {
    try {
      _subjectId = options.subjectId ??
          (options.autoGenerateSubjectId
              ? await _storage.getOrCreateSubjectId()
              : null);

      final config = await _api.getConfig();
      _config = config;
      _regulation = config.resolvedRegulation;
      _language = options.language ?? config.property.defaultLanguage ?? 'en';
      if (config.requireCaptcha) _logger.warn(captchaWarning);

      var found = false;
      final sid = _subjectId;
      if (sid != null && sid.isNotEmpty) {
        found = await _restoreConsent(sid);
      }

      _isLoading = false;
      _notify();

      if (options.autoShow && !found) {
        _isSheetVisible = true;
        _notify();
        options.onOpen?.call();
      }
    } catch (e) {
      _logger.warn('Failed to initialize: $e');
      _isLoading = false;
      _notify();
    }
  }

  Future<bool> _restoreConsent(String sid) async {
    ConsentLookup? lookup;
    try {
      lookup = await _api.getConsent(sid);
    } catch (e) {
      _logger.warn('Failed to load consent, using local cache: $e');
    }
    final saved = lookup?.consent;
    if (saved != null) {
      _consent = normalizeConsentState(saved.cookieConsents);
      if (saved.marketingConsents != null) {
        _marketingConsent = Map.of(saved.marketingConsents!);
      }
      await _storage.saveConsent(_consent);
      return true;
    }
    if (lookup?.expired == true) {
      await _storage.clearConsent();
      return false;
    }
    final cached = await _storage.loadConsent();
    if (cached != null) {
      _consent = cached;
      return true;
    }
    return false;
  }

  bool hasConsent(String category) => _consent[category] == true;

  bool hasMarketingConsent(String channel) =>
      _marketingConsent[channel] == true;

  Future<void> acceptAll() async {
    final next = defaultConsentState();
    final config = _config;
    if (config != null) {
      for (final category in config.categories) {
        if (category.enabled) next[category.code] = true;
      }
    } else {
      next.updateAll((code, value) => true);
    }
    _consent = next;
    _isSheetVisible = false;
    _notify();
    await _submit();
    options.onAccept?.call(
      ConsentAcceptEvent(scope: ConsentScope.all, consent: consent),
    );
  }

  Future<void> rejectAll() async {
    _consent = defaultConsentState();
    _isSheetVisible = false;
    _notify();
    await _submit();
    options.onReject?.call(ConsentRejectEvent(consent: consent));
  }

  Future<void> updateConsent(Map<String, bool> updates) async {
    _consent = normalizeConsentState({..._consent, ...updates});
    _notify();
    await _submit();
  }

  Future<void> updateMarketingConsent(Map<String, bool> updates) async {
    _marketingConsent = {..._marketingConsent, ...updates};
    _notify();
    await _submit();
  }

  /// Commits the sheet's selection: closes the sheet, records it, and reports
  /// through `onSave`.
  Future<void> savePreferences(Map<String, bool> next) async {
    _consent = normalizeConsentState(next);
    _isSheetVisible = false;
    _notify();
    await _submit();
    options.onSave?.call(ConsentSaveEvent(consent: consent));
  }

  void showSheet() {
    _isSheetVisible = true;
    _notify();
    options.onOpen?.call();
  }

  /// Host-initiated close. Emits nothing.
  void hideSheet() {
    if (!_isSheetVisible) return;
    _isSheetVisible = false;
    _notify();
  }

  /// The visitor backed out without answering. Reports through `onClose`.
  void dismissSheet() {
    if (!_isSheetVisible) return;
    _isSheetVisible = false;
    _notify();
    options.onClose?.call();
  }

  Future<void> resetConsent() async {
    _consent = defaultConsentState();
    _marketingConsent = {};
    _notify();
    await _storage.clearAll();
    _subjectId = options.subjectId ??
        (options.autoGenerateSubjectId
            ? await _storage.getOrCreateSubjectId()
            : null);
  }

  Future<void> _submit() async {
    final sid = _subjectId;
    if (sid == null || sid.isEmpty) {
      _logger.log('No subject id; consent kept locally only');
      return;
    }
    final cookieConsents = Map<String, bool>.of(_consent);
    final marketingConsents = Map<String, bool>.of(_marketingConsent);
    try {
      await _api.submitConsent(
        subjectId: sid,
        cookieConsents: cookieConsents,
        marketingConsents: marketingConsents,
        consentMethod: 'sdk',
      );
      await _storage.saveConsent(cookieConsents);
      options.onConsentChange?.call(
        Map.unmodifiable(cookieConsents),
        Map.unmodifiable(marketingConsents),
      );
    } catch (e) {
      _logger.warn('Failed to submit consent: $e');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsApi) _api.close();
    super.dispose();
  }
}
