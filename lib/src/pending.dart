import 'consent_state.dart';
import 'json.dart';

/// A decision ConsentIQ asked to resend later (429), retried once per launch
/// without a captcha.
class PendingDecision {
  const PendingDecision({
    required this.cookieConsents,
    required this.marketingConsents,
    required this.attempts,
    required this.createdAt,
    required this.subjectId,
    required this.propertyKey,
    required this.apiUrl,
  });

  static const int maxAttempts = 3;
  static const Duration maxAge = Duration(days: 7);

  final ConsentState cookieConsents;
  final MarketingConsentState marketingConsents;
  final int attempts;
  final DateTime createdAt;

  // Whose decision it is and where it goes: resent only to the same person,
  // property and server.
  final String subjectId;
  final String propertyKey;
  final String apiUrl;

  bool isSpent(DateTime now) =>
      attempts >= maxAttempts || now.difference(createdAt) > maxAge;

  bool belongsTo(String subjectId, String propertyKey, String apiUrl) =>
      this.subjectId == subjectId &&
      this.propertyKey == propertyKey &&
      this.apiUrl == apiUrl;

  PendingDecision retried() => PendingDecision(
        cookieConsents: cookieConsents,
        marketingConsents: marketingConsents,
        attempts: attempts + 1,
        createdAt: createdAt,
        subjectId: subjectId,
        propertyKey: propertyKey,
        apiUrl: apiUrl,
      );

  Map<String, Object?> toJson() => {
        'cookieConsents': cookieConsents,
        'marketingConsents': marketingConsents,
        'attempts': attempts,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'subjectId': subjectId,
        'propertyKey': propertyKey,
        'apiUrl': apiUrl,
      };

  static PendingDecision? fromJson(Object? json) {
    final map = asMap(json);
    final created = map['createdAt'];
    final attempts = map['attempts'];
    final subjectId = map['subjectId'];
    final propertyKey = map['propertyKey'];
    final apiUrl = map['apiUrl'];
    if (created is! int ||
        attempts is! int ||
        subjectId is! String ||
        propertyKey is! String ||
        apiUrl is! String) {
      return null;
    }
    return PendingDecision(
      cookieConsents: asBoolMap(map['cookieConsents']),
      marketingConsents: asBoolMap(map['marketingConsents']),
      attempts: attempts,
      createdAt: DateTime.fromMillisecondsSinceEpoch(created),
      subjectId: subjectId,
      propertyKey: propertyKey,
      apiUrl: apiUrl,
    );
  }
}

/// A refusal that resending the same decision cannot change.
bool dropsTheDecision(int? statusCode) =>
    statusCode == 400 ||
    statusCode == 404 ||
    statusCode == 409 ||
    statusCode == 422;
