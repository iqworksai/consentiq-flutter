import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'config.dart';
import 'consent_state.dart';
import 'log.dart';
import 'models.dart';

const List<String> defaultMarketingChannels = [
  'email',
  'sms',
  'whatsapp',
  'push',
];

class FormConsentResult {
  const FormConsentResult({required this.submission, required this.consents});

  final ConsentSubmission submission;
  final MarketingConsentState consents;
}

/// Marketing-channel consent collected from an app's own form, recorded with
/// `consentMethod: "form"` against a subject the app identifies.
class FormConsent extends ChangeNotifier {
  FormConsent({
    required String propertyKey,
    String apiUrl = defaultApiUrl,
    required this.subjectId,
    this.subjectType = 'user',
    this.channels = defaultMarketingChannels,
    this.onConsentSubmitted,
    this.onConsentChange,
    ConsentIQApiClient? apiClient,
    bool debug = false,
  })  : _api = apiClient ??
            ConsentIQApiClient(
              propertyKey: propertyKey,
              apiUrl: apiUrl,
              debug: debug,
            ),
        _ownsApi = apiClient == null,
        _logger = ConsentIQLogger(debug: debug) {
    _consents = _cleared();
  }

  final String subjectId;

  /// `visitor`, `user` or `subscriber`.
  final String subjectType;
  final List<String> channels;
  final void Function(FormConsentResult result)? onConsentSubmitted;
  final void Function(MarketingConsentState consents)? onConsentChange;
  final ConsentIQApiClient _api;
  final bool _ownsApi;
  final ConsentIQLogger _logger;

  late MarketingConsentState _consents;
  bool _isSubmitting = false;

  MarketingConsentState get consents => Map.unmodifiable(_consents);
  bool get isSubmitting => _isSubmitting;

  MarketingConsentState _cleared() => {for (final c in channels) c: false};

  void toggleChannel(String channel) =>
      setChannel(channel, !(_consents[channel] ?? false));

  void setChannel(String channel, bool value) {
    _consents = {..._consents, channel: value};
    notifyListeners();
    onConsentChange?.call(consents);
  }

  /// Posts the current selection. Returns null when the subject id is empty or
  /// the request fails; the failure is logged.
  Future<FormConsentResult?> submit() async {
    if (subjectId.isEmpty) return null;
    _isSubmitting = true;
    notifyListeners();
    try {
      final submission = await _api.submitConsent(
        subjectId: subjectId,
        subjectType: subjectType,
        marketingConsents: Map.of(_consents),
        consentMethod: 'form',
      );
      final result = FormConsentResult(
        submission: submission,
        consents: consents,
      );
      onConsentSubmitted?.call(result);
      return result;
    } catch (e) {
      _logger.warn('Failed to submit form consent: $e');
      return null;
    } finally {
      _isSubmitting = false;
      notifyListeners();
    }
  }

  void reset() {
    _consents = _cleared();
    notifyListeners();
  }

  @override
  void dispose() {
    if (_ownsApi) _api.close();
    super.dispose();
  }
}
