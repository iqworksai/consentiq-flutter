import 'consent_state.dart';

enum ConsentScope { all, required }

class ConsentAcceptEvent {
  const ConsentAcceptEvent({required this.scope, required this.consent});

  /// Always [ConsentScope.all] in this SDK; there is no accept-required path.
  final ConsentScope scope;
  final ConsentState consent;
}

class ConsentRejectEvent {
  const ConsentRejectEvent({required this.consent});

  final ConsentState consent;
}

class ConsentSaveEvent {
  const ConsentSaveEvent({required this.consent});

  final ConsentState consent;
}

typedef ConsentChangeCallback = void Function(
    ConsentState consent, MarketingConsentState marketingConsent);
typedef ConsentAcceptCallback = void Function(ConsentAcceptEvent event);
typedef ConsentRejectCallback = void Function(ConsentRejectEvent event);
typedef ConsentSaveCallback = void Function(ConsentSaveEvent event);

const String defaultApiUrl = 'https://consent.iqworks.ai';

class ConsentIQConfig {
  const ConsentIQConfig({
    required this.propertyKey,
    this.apiUrl = defaultApiUrl,
    this.subjectId,
    this.autoGenerateSubjectId = true,
    this.language,
    this.autoShow = true,
    this.debug = false,
    this.onConsentChange,
    this.onOpen,
    this.onAccept,
    this.onReject,
    this.onSave,
    this.onClose,
  });

  /// The property's public key from the ConsentIQ dashboard.
  final String propertyKey;
  final String apiUrl;

  /// A subject id supplied by the app. When null and [autoGenerateSubjectId]
  /// is true, a UUID is generated once and persisted.
  final String? subjectId;
  final bool autoGenerateSubjectId;

  /// Overrides the property's default language.
  final String? language;

  /// Show the sheet on init when no consent has been recorded.
  final bool autoShow;
  final bool debug;

  /// Fires after every recorded write.
  final ConsentChangeCallback? onConsentChange;

  /// Fires whenever the sheet is shown, on init or through `showSheet()`.
  final void Function()? onOpen;
  final ConsentAcceptCallback? onAccept;
  final ConsentRejectCallback? onReject;
  final ConsentSaveCallback? onSave;

  /// Fires only when the visitor backs out of the sheet without answering.
  final void Function()? onClose;
}
