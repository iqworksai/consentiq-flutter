import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'attestation.dart';
import 'captcha.dart';
import 'pending.dart';
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
        _language = options.language ?? 'en' {
    _api.attestation ??= AppAttestation(
      server: _api,
      apiUrl: _api.apiUrl,
      propertyKey: options.propertyKey,
      playIntegrityCloudProjectNumber: options.playIntegrityCloudProjectNumber,
    );
  }

  final ConsentIQConfig options;
  final ConsentIQApiClient _api;
  final bool _ownsApi;
  final ConsentStorage _storage;
  final CaptchaTokenSource? _captchaTokenSource;
  final TcfKeyStore _tcfKeys;
  final ConsentIQLogger _logger;

  /// The clock pending decisions are aged by.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  ConsentState _consent = defaultConsentState();
  MarketingConsentState _marketingConsent = {};
  PropertyConfig? _config;
  bool _isLoading = true;
  bool _isSheetVisible = false;
  String _language;
  String? _regulation;
  String? _subjectId;
  Future<void>? _initFuture;
  // Bumped by resetConsent, so a submit that started before a reset cannot
  // store its 429 after it.
  int _resetGeneration = 0;
  // When the server's own record for this person was made, from the last
  // lookup.
  DateTime? _serverConsentedAt;
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
      _subjectId = await _resolveSubjectId();

      final config = await _api.getConfig();
      _config = config;
      _regulation = config.resolvedRegulation;
      _language = options.language ?? config.property.defaultLanguage ?? 'en';

      var found = false;
      final sid = _subjectId;
      if (sid != null && sid.isNotEmpty) {
        // A decision dropped unrecorded leaves nothing granted: neither an older
        // server record nor the local copy answers for it, so the sheet asks
        // again.
        if (!await _storage.isUnrecorded(options.propertyKey)) {
          found = await _restoreConsent(sid);
        }
        switch (await _resendPending(sid)) {
          case _ResendOutcome.recorded:
            found = true;
          case _ResendOutcome.dropped:
            found = false;
          case _ResendOutcome.none:
            break;
        }
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
    // An id the app chose is read only with its identity token; without one
    // the local copy stands, since the open lookup reads only ids this SDK
    // generated.
    ConsentLookup? lookup;
    if (_subjectSource == null || options.identityToken != null) {
      try {
        lookup = await _api.getConsent(sid, identityToken: _identityToken);
      } on ConsentIQApiException catch (e) {
        if (e.statusCode == 403) {
          // The token did not verify for this subject, so this device's copy
          // cannot answer for them: the sheet asks again, and the app is told.
          _logger.warn('Consent lookup refused', e);
          await _storage.clearConsent();
          options.onError?.call(ConsentIQError(
              source: 'consent', code: 'refused', message: e.message));
          return false;
        }
        _logger.warn('Failed to load consent, using local cache', e);
      } catch (e) {
        _logger.warn('Failed to load consent, using local cache', e);
      }
    }
    final saved = lookup?.consent;
    _serverConsentedAt =
        saved == null ? null : DateTime.tryParse(saved.consentedAt);
    if (saved != null) {
      _consent = normalizeConsentState(saved.cookieConsents);
      if (saved.marketingConsents != null) {
        _marketingConsent = Map.of(saved.marketingConsents!);
      }
      await _storage.saveConsentFor(_consent, sid);
      return true;
    }
    if (lookup?.expired == true) {
      await _storage.clearConsent();
      await _clearTcfDecision();
      return false;
    }
    final cached = await _storage.loadConsentFor(sid);
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
    _resetGeneration++;
    await _clearTcfDecision();
    await _storage.clearAll();
    _subjectId = await _resolveSubjectId();
  }

  Future<String?> _resolveSubjectId() async {
    final supplied = options.subjectId;
    if (supplied != null) {
      if (isValidSubjectId(supplied)) return supplied;
      _logger.warn(invalidSubjectIdMessage);
      options.onError?.call(const ConsentIQError(
          source: 'config',
          code: 'invalid-subject-id',
          message: invalidSubjectIdMessage));
      return null;
    }
    return options.autoGenerateSubjectId
        ? await _storage.getOrCreateSubjectId()
        : null;
  }

  /// `site` when the subject id in use is the app's own, not a generated one.
  String? get _subjectSource =>
      options.subjectId != null && _subjectId == options.subjectId
          ? siteSubjectSource
          : null;

  /// The identity token, only where it can verify: with the app's own subject
  /// id. A generated id is random, so a token signed for the app's user never
  /// matches it.
  String? get _identityToken =>
      _subjectSource != null ? options.identityToken : null;

  int? get _noticeVersion => _config?.banner.noticeVersion;

  List<String> get _categoryCodes =>
      (_config?.categories.map((c) => c.code).toList() ?? <String>[])..sort();

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
    // The decision applies at once and stands locally; the server record makes
    // it stand across launches.
    await _storage.saveConsentFor(cookieConsents, sid);
    final decision = _UnrecordedDecision(
        cookieConsents, marketingConsents, sid, _resetGeneration);
    final config = _config;
    final tokenSource = _captchaTokenSource ??
        CaptchaController.forProperty(_api.apiUrl, options.propertyKey).token;
    String? captchaToken;
    if (config != null && requiresCaptcha(config)) {
      try {
        captchaToken = await tokenSource();
      } catch (_) {
        _logger.warn(captchaFailedWarning);
        await _settleFailure(null, captchaFailedWarning, decision);
        return;
      }
    }
    try {
      await submitAnsweringChallenge(
        firstToken: captchaToken,
        tokenSource: tokenSource,
        send: (token) => _api.submitConsent(
          subjectId: sid,
          cookieConsents: cookieConsents,
          marketingConsents: marketingConsents,
          consentMethod: 'sdk',
          captchaToken: token,
          identityToken: _identityToken,
          subjectSource: _subjectSource,
        ),
      );
      if (decision.generation != _resetGeneration) return;
      await _storage.clearPending();
      await _storage.clearUnrecorded();
      options.onConsentChange?.call(
        Map.unmodifiable(cookieConsents),
        Map.unmodifiable(marketingConsents),
      );
    } on CaptchaException {
      _logger.warn(captchaFailedWarning);
      await _settleFailure(null, captchaFailedWarning, decision);
    } on ConsentIQApiException catch (e) {
      _logger.warn('Failed to submit consent', e);
      await _settleFailure(e.statusCode, e.message, decision);
    } catch (e) {
      _logger.warn('Failed to submit consent', e);
      await _settleFailure(null, '$e', decision);
    }
  }

  // A submit ConsentIQ did not record. Retryable (no answer, a 5xx, a 429, an
  // unanswered challenge) keeps it as the pending decision, replacing any
  // earlier one. Anything else, or any failure on a property that requires a
  // captcha on every submit (a resend cannot carry one), is final: the decision
  // and its local copy are dropped, the next launch asks again, and the app is
  // told.
  Future<void> _settleFailure(
      int? statusCode, String? message, _UnrecordedDecision decision) async {
    // A submit that started before a reset belongs to the state the reset
    // cleared.
    if (decision.generation != _resetGeneration) return;
    final config = _config;
    if (isFinalStatus(statusCode) ||
        (config != null && requiresCaptcha(config))) {
      await _dropUnrecordedDecision();
      options.onError?.call(
        ConsentIQError(source: 'consent', code: 'refused', message: message),
      );
      return;
    }
    await _storage.savePending(PendingDecision(
      cookieConsents: decision.cookieConsents,
      marketingConsents: decision.marketingConsents,
      attempts: 0,
      createdAt: clock(),
      subjectId: decision.subjectId,
      propertyKey: options.propertyKey,
      apiUrl: _api.apiUrl,
      noticeVersion: _noticeVersion,
      categoryCodes: _categoryCodes,
    ));
  }

  // The decision was never recorded and never will be: its local copy goes
  // with it, and the next launch asks again with nothing granted rather than
  // restoring an older choice.
  Future<void> _dropUnrecordedDecision() async {
    await _storage.clearPending();
    await _storage.clearConsent();
    await _storage.markUnrecorded(options.propertyKey);
  }

  // At launch the dropped decision's local copy may already be applied, so it
  // is taken back too.
  Future<_ResendOutcome> _dropAtLaunch() async {
    await _dropUnrecordedDecision();
    _consent = defaultConsentState();
    _marketingConsent = {};
    return _ResendOutcome.dropped;
  }

  // Resends a decision ConsentIQ has not recorded, once per launch and never
  // with a captcha.
  Future<_ResendOutcome> _resendPending(String sid) async {
    final pending = await _storage.loadPending();
    if (pending == null) return _ResendOutcome.none;
    if (!pending.belongsTo(sid, options.propertyKey, _api.apiUrl)) {
      // Another person's, property's or server's: never sent here.
      await _storage.clearPending();
      return _ResendOutcome.none;
    }
    // A record the server made after this decision is the newer choice, so it
    // wins.
    final serverAt = _serverConsentedAt;
    if (serverAt != null && serverAt.isAfter(pending.createdAt)) {
      await _storage.clearPending();
      return _ResendOutcome.none;
    }
    final config = _config;
    if (pending.isSpent(clock()) ||
        !pending.matches(_noticeVersion, _categoryCodes) ||
        (config != null && requiresCaptcha(config))) {
      return _dropAtLaunch();
    }
    await _storage.savePending(pending.retried());
    try {
      await _api.submitConsent(
        subjectId: sid,
        cookieConsents: pending.cookieConsents,
        marketingConsents: pending.marketingConsents,
        consentMethod: 'sdk',
        identityToken: _identityToken,
        subjectSource: _subjectSource,
        noticeVersion: pending.noticeVersion,
      );
    } on ConsentIQApiException catch (e) {
      _logger.log('Pending consent not recorded: ${e.message}');
      if (isFinalStatus(e.statusCode)) {
        options.onError?.call(
          ConsentIQError(
              source: 'consent', code: 'refused', message: e.message),
        );
        return _dropAtLaunch();
      }
      return _ResendOutcome.none;
    } catch (e) {
      _logger.log('Pending consent not recorded: $e');
      return _ResendOutcome.none;
    }
    await _storage.clearPending();
    await _storage.clearUnrecorded();
    _consent = normalizeConsentState(pending.cookieConsents);
    _marketingConsent = Map.of(pending.marketingConsents);
    await _storage.saveConsentFor(_consent, sid);
    options.onConsentChange?.call(
      Map.unmodifiable(_consent),
      Map.unmodifiable(_marketingConsent),
    );
    return _ResendOutcome.recorded;
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
        subjectSource: _subjectSource,
        identityToken: _identityToken,
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
      final sid = _subjectId;
      if (sid != null && sid.isNotEmpty) {
        await _storage.saveConsentFor(_consent, sid);
      }
    }
    _consentFound = true;
    if (decision.recorded) {
      await _storage.clearUnrecorded();
    } else {
      // A resend could not carry the TC string, so an unrecorded decision is
      // not kept: it holds for this session and the next launch asks again.
      await _dropUnrecordedDecision();
      await _storage.clearTcf();
    }
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
    if (!decision.recorded) {
      final status = decision.recordStatus;
      options.onError?.call(ConsentIQError(
        source: 'consent',
        code: 'refused',
        message: 'TCF decision not recorded'
            '${status == null ? '' : ' (status $status)'}',
      ));
      return;
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

enum _ResendOutcome { none, recorded, dropped }

class _UnrecordedDecision {
  const _UnrecordedDecision(this.cookieConsents, this.marketingConsents,
      this.subjectId, this.generation);

  final ConsentState cookieConsents;
  final MarketingConsentState marketingConsents;
  final String subjectId;
  final int generation;
}
