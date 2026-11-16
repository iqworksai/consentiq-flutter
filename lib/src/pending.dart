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
  });

  static const int maxAttempts = 3;
  static const Duration maxAge = Duration(days: 7);

  final ConsentState cookieConsents;
  final MarketingConsentState marketingConsents;
  final int attempts;
  final DateTime createdAt;

  bool isSpent(DateTime now) =>
      attempts >= maxAttempts || now.difference(createdAt) > maxAge;

  PendingDecision retried() => PendingDecision(
        cookieConsents: cookieConsents,
        marketingConsents: marketingConsents,
        attempts: attempts + 1,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'cookieConsents': cookieConsents,
        'marketingConsents': marketingConsents,
        'attempts': attempts,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  static PendingDecision? fromJson(Object? json) {
    final map = asMap(json);
    final created = map['createdAt'];
    final attempts = map['attempts'];
    if (created is! int || attempts is! int) return null;
    return PendingDecision(
      cookieConsents: asBoolMap(map['cookieConsents']),
      marketingConsents: asBoolMap(map['marketingConsents']),
      attempts: attempts,
      createdAt: DateTime.fromMillisecondsSinceEpoch(created),
    );
  }
}

/// A refusal that resending the same decision cannot change.
bool dropsTheDecision(int? statusCode) =>
    statusCode == 400 ||
    statusCode == 404 ||
    statusCode == 409 ||
    statusCode == 422;
