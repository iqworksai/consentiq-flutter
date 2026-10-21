import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'captcha.dart';
import 'config.dart';
import 'consent_state.dart';
import 'log.dart';
import 'models.dart';
import 'storage.dart';
import 'tcf.dart';
import 'tcf_key_store.dart';

@Deprecated('Unused since 1.1.0, which passes the captcha check itself.')
const String captchaWarning =
    'This property requires a captcha, which mobile SDKs cannot satisfy. '
    'Turn off "Require captcha" for this property in the ConsentIQ dashboard.';

/// The consent state machine. Create one per app, call [init] once, and read
/// it through [ConsentIQProvider] or listen to it directly.
class ConsentIQ extends ChangeNotifier {
  ConsentIQ(
    this.options, {
    ConsentIQApiClient? apiClient,
    ConsentStorage? storage,
    CaptchaTokenSource? captchaTokenSource,
    TcfKeyStore? tcfKeyStore,
  })  : _api = apiClient ??
            ConsentIQApiClient(
              propertyKey: options.propertyKey,
              apiUrl: options.apiUrl,
              debug: options.debug,
            ),
        _ownsApi = apiClient == null,
        _storage = storage ?? ConsentStorage(),
        _captchaTokenSource = captchaTokenSource,
        _tcfKeys = tcfKeyStore ?? const TcfKeyStore(),
        _logger = ConsentIQLogger(debug: options.debug),
        _language = options.language ?? 'en';

  final ConsentIQConfig options;
  final ConsentIQApiClient _api;
  final bool _ownsApi;
  final ConsentStorage _storage;
  final CaptchaTokenSource? _captchaTokenSource;
  final TcfKeyStore _tcfKeys;
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
  bool _consentFound = false;
  bool _tcfMode = false;
  bool _tcfFallback = false;
  bool _tcfOpenQueued = false;
  bool _ownsTcfKeys = false;
  TcfSession? _tcf;

  ConsentState get consent => Map.unmodifiable(_consent);
  MarketingConsentState get marketingConsent =>
      Map.unmodifiable(_marketingConsent);
  PropertyConfig? get config => _config;
  bool get isLoading => _isLoading;
  bool get isSheetVisible => _isSheetVisible;
  String get language => _language;
  String? get regulation => _regulation;
  String? get subjectId => _subjectId;

  /// Whether the property runs IAB TCF here, so the TCF page takes the
  /// consent sheet's place.
  bool get isTcfActive => _tcfMode;

  /// Whether the TCF page is on screen.
  bool get isTcfVisible => _tcf?.isPresented ?? false;

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

      var found = false;
      final sid = _subjectId;
      if (sid != null && sid.isNotEmpty) {
        found = await _restoreConsent(sid);
      }

      _consentFound = found;

      final tcf = config.tcf;
      final tcfOn = tcf != null && tcf.isActive;
      _tcfMode = tcfOn && tcf.gdprApplies;
      if (_tcfMode) _isSheetVisible = false;

      _isLoading = false;
      _notify();

      if (tcfOn) {
        await _writeTcfKeys((keys) => keys.writeCmp(
              cmpId: tcf.cmpId,
              cmpVersion: tcf.cmpVersion,
            ));
        if (tcf.gdprApplies) {
          if (options.autoShow) {
            unawaited(_startTcf(reopen: false));
          } else {
            await _writeTcfKeys((keys) => keys.writeGdprApplies(true));
          }
          return;
        }
        await _writeTcfKeys((keys) => keys.writeGdprApplies(false));
      } else {
        await _clearOwnedTcfKeys();
      }

      if (options.autoShow && !found) _showNativeSheet();
    } catch (e) {
      _logger.warn('Failed to initialize', e);
      _isLoading = false;
      _notify();
    }
  }

  Future<bool> _restoreConsent(String sid) async {
    ConsentLookup? lookup;
    try {
      lookup = await _api.getConsent(sid);
    } catch (e) {
      _logger.warn('Failed to load consent, using local cache', e);
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
      await _clearTcfDecision();
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

  /// Shows the consent sheet, or the TCF page when [isTcfActive].
  void showSheet() {
    if (_tcfMode) {
      showTcfPreferences();
      return;
    }
    _showNativeSheet();
  }

  void _showNativeSheet() {
    _isSheetVisible = true;
    _notify();
    options.onOpen?.call();
  }

  /// Opens the TCF page on its detail layer, where the visitor can review or
  /// change their choices and close it. Without a stored TCF decision it
  /// opens as the first prompt. Does nothing unless [isTcfActive]. Called
  /// while the start-up check is still running, it opens once that ends.
  void showTcfPreferences() {
    if (!_tcfMode) return;
    final running = _tcf;
    if (running != null) {
      if (!running.isPresented) _tcfOpenQueued = true;
      return;
    }
    unawaited(_startTcf(reopen: true));
  }

  /// Host-initiated close of the sheet or the TCF page. Emits nothing.
  void hideSheet() {
    final tcf = _tcf;
    if (tcf != null && tcf.isPresented) {
      _endTcf(tcf);
      return;
    }
    if (!_isSheetVisible) return;
    _isSheetVisible = false;
    _notify();
  }

  /// The visitor backed out of the sheet or the TCF page without answering.
  /// Reports through `onClose`.
  void dismissSheet() {
    final tcf = _tcf;
    if (tcf != null && tcf.isPresented) {
      _endTcf(tcf);
      options.onClose?.call();
      return;
    }
    if (!_isSheetVisible) return;
    _isSheetVisible = false;
    _notify();
    options.onClose?.call();
  }

  Future<void> resetConsent() async {
    _consent = defaultConsentState();
    _marketingConsent = {};
    _notify();
    await _clearTcfDecision();
    await _storage.clearAll();
    _subjectId = options.subjectId ??
        (options.autoGenerateSubjectId
            ? await _storage.getOrCreateSubjectId()
            : null);
  }

  Future<void> _submit() async {
    // The sheet stood in for the TCF page, so the last TC string no longer
    // matches what the visitor chose.
    if (_tcfFallback) {
      _tcfFallback = false;
      await _clearTcfDecision();
    }
    final sid = _subjectId;
    if (sid == null || sid.isEmpty) {
      _logger.log('No subject id; consent kept locally only');
      return;
    }
    final cookieConsents = Map<String, bool>.of(_consent);
    final marketingConsents = Map<String, bool>.of(_marketingConsent);
    final config = _config;
    String? captchaToken;
    if (config != null && requiresCaptcha(config)) {
      try {
        captchaToken = await (_captchaTokenSource ??
            CaptchaController.forApiUrl(_api.apiUrl).token)();
      } catch (_) {
        _logger.warn(captchaFailedWarning);
        return;
      }
    }
    try {
      await _api.submitConsent(
        subjectId: sid,
        cookieConsents: cookieConsents,
        marketingConsents: marketingConsents,
        consentMethod: 'sdk',
        captchaToken: captchaToken,
      );
      await _storage.saveConsent(cookieConsents);
      options.onConsentChange?.call(
        Map.unmodifiable(cookieConsents),
        Map.unmodifiable(marketingConsents),
      );
    } catch (e) {
      _logger.warn('Failed to submit consent', e);
    }
  }

  Future<void> _startTcf({required bool reopen}) async {
    if (_tcf != null || _disposed) return;
    late final TcfSession session;
    session = _tcf = TcfSession(
      pageUrl: tcfPageUrl(_api.apiUrl, options.propertyKey),
      onMessage: (message) =>
          _onTcfMessage(session, message, requested: reopen),
    );
    try {
      await session.open();
      await session.ready.timeout(tcfReadyTimeout);
      final stored = await _storage.loadTcf();
      if (!identical(_tcf, session)) return;
      session.reopen = reopen && stored != null;
      await session.start(
        subjectId: _subjectId ?? '',
        stored: stored,
        consent: stored == null ? null : Map.of(_consent),
      );
    } catch (e) {
      if (!identical(_tcf, session)) return;
      final code = switch (e) {
        TimeoutException() => 'timeout',
        TcfPageException(:final code) => code,
        _ => 'load',
      };
      await _onTcfMessage(session, TcfError(code), requested: reopen);
    }
  }

  // [requested] is a run the app asked for, which falls back to the sheet
  // even when consent is on record.
  Future<void> _onTcfMessage(
    TcfSession session,
    TcfMessage message, {
    required bool requested,
  }) async {
    if (!identical(_tcf, session) || session.isReleased) return;
    final wanted = requested || _tcfOpenQueued;
    switch (message) {
      case TcfReady():
        return;
      case TcfShow():
        if (session.isPresented) return;
        _tcfOpenQueued = false;
        session.present();
        _notify();
        options.onOpen?.call();
      case TcfCurrent():
        _endTcf(session);
        await _writeTcfKeys((keys) => keys.writeGdprApplies(true));
        _openQueuedTcf();
      case TcfDecision():
        await _applyTcfDecision(session, message);
        _openQueuedTcf();
      case TcfClosed():
        final wasShown = session.isPresented;
        _endTcf(session);
        if (wasShown) options.onClose?.call();
        _openQueuedTcf();
      case TcfNotApplicable():
        _tcfOpenQueued = false;
        _endTcf(session);
        _tcfMode = false;
        _tcfFallback = true;
        await _writeTcfKeys((keys) => keys.writeGdprApplies(false));
        _fallBackToSheet(requested: wanted);
      case TcfError(code: tcfOffCode):
        _tcfOpenQueued = false;
        _endTcf(session);
        _tcfMode = false;
        await _clearOwnedTcfKeys();
        _fallBackToSheet(requested: wanted);
      // TCF stays on: the next open tries the page again.
      case TcfError(:final code):
        _tcfOpenQueued = false;
        _endTcf(session);
        _tcfFallback = true;
        _reportError(code);
        _fallBackToSheet(requested: wanted);
    }
  }

  void _openQueuedTcf() {
    if (!_tcfOpenQueued || _disposed) return;
    _tcfOpenQueued = false;
    showTcfPreferences();
  }

  // The page has already recorded this consent, so it is not submitted again.
  Future<void> _applyTcfDecision(
    TcfSession session,
    TcfDecision decision,
  ) async {
    _tcf = null;
    // Without the keys the record would claim a decision vendors cannot see,
    // so the next launch asks again instead.
    if (await _writeTcfKeys((keys) => keys.write(decision.keys))) {
      await _storage.saveTcf(decision.stored);
    } else {
      await _storage.clearTcf();
    }
    _tcfFallback = false;
    final consent = decision.consent;
    if (consent != null) {
      _consent = normalizeConsentState(consent);
      await _storage.saveConsent(_consent);
    }
    _consentFound = true;
    session.release();
    if (_disposed) return;
    _notify();
    switch (decision.scope ?? _inferScope(consent)) {
      case 'all':
        options.onAccept?.call(
          ConsentAcceptEvent(scope: ConsentScope.all, consent: this.consent),
        );
      case 'none':
        options.onReject?.call(ConsentRejectEvent(consent: this.consent));
      default:
        options.onSave?.call(ConsentSaveEvent(consent: this.consent));
    }
    options.onConsentChange?.call(
      Map.unmodifiable(_consent),
      Map.unmodifiable(_marketingConsent),
    );
  }

  String _inferScope(ConsentState? consent) {
    if (consent == null) return 'custom';
    final optional = (_config?.categories ?? const <CategoryInfo>[])
        .where((c) => c.enabled && !c.isRequired)
        .map((c) => c.code)
        .toList();
    if (optional.isEmpty) return 'custom';
    if (optional.every((code) => consent[code] == true)) return 'all';
    if (optional.every((code) => consent[code] != true)) return 'none';
    return 'custom';
  }

  void _endTcf(TcfSession session) {
    final wasShown = session.isPresented;
    if (identical(_tcf, session)) _tcf = null;
    session.release();
    if (wasShown) _notify();
  }

  void _fallBackToSheet({required bool requested}) {
    if (_disposed) return;
    if (requested || (options.autoShow && !_consentFound)) _showNativeSheet();
  }

  // A successful write makes the keys this SDK's, which is what lets it
  // remove them later; removing never claims them.
  Future<bool> _writeTcfKeys(
    Future<void> Function(TcfKeyStore keys) write, {
    bool claims = true,
  }) async {
    try {
      await write(_tcfKeys);
    } catch (_) {
      _reportError('key-store');
      return false;
    }
    if (claims && !_ownsTcfKeys) {
      _ownsTcfKeys = true;
      await _storage.saveTcfCmpWritten();
    }
    return true;
  }

  // Only keys this SDK wrote: another CMP in the app may own them otherwise.
  Future<void> _clearTcfDecision() async {
    await _storage.clearTcf();
    if (!await _storage.loadTcfCmpWritten()) return;
    await _writeTcfKeys((keys) => keys.clearDecision(), claims: false);
  }

  Future<void> _clearOwnedTcfKeys() async {
    if (!await _storage.loadTcfCmpWritten()) return;
    await _storage.clearTcf();
    if (await _writeTcfKeys((keys) => keys.clearAll(), claims: false)) {
      _ownsTcfKeys = false;
      await _storage.clearTcfCmpWritten();
    }
  }

  void _reportError(String code) {
    _logger.warn('IAB TCF failed ($code)');
    options.onError?.call(ConsentIQError(source: 'tcf', code: code));
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tcf?.release();
    _tcf = null;
    if (_ownsApi) _api.close();
    super.dispose();
  }
}

/// The TCF run [ConsentIQ] has under way, for the consent sheet to present.
TcfSession? tcfSessionOf(ConsentIQ consentIQ) => consentIQ._tcf;
