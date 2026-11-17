import 'consent_state.dart';
import 'json.dart';

/// A decision ConsentIQ has not recorded yet (no answer, a 5xx, a 429, an
/// unanswered challenge), resent once per launch without a captcha.
class PendingDecision {
  const PendingDecision({
    required this.cookieConsents,
    required this.marketingConsents,
    required this.attempts,
    required this.createdAt,
    required this.subjectId,
    required this.propertyKey,
    required this.apiUrl,
    this.noticeVersion,
    this.categoryCodes = const [],
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

  // What it was decided against: one made under another notice or category set
  // is never resent.
  final int? noticeVersion;
  final List<String> categoryCodes;

  bool isSpent(DateTime now) =>
      attempts >= maxAttempts || now.difference(createdAt) > maxAge;

  bool belongsTo(String subjectId, String propertyKey, String apiUrl) =>
      this.subjectId == subjectId &&
      this.propertyKey == propertyKey &&
      this.apiUrl == apiUrl;

  bool matches(int? noticeVersion, List<String> categoryCodes) =>
      this.noticeVersion == noticeVersion &&
      this.categoryCodes.join('\u0000') == categoryCodes.join('\u0000');

  PendingDecision retried() => PendingDecision(
        cookieConsents: cookieConsents,
        marketingConsents: marketingConsents,
        attempts: attempts + 1,
        createdAt: createdAt,
        subjectId: subjectId,
        propertyKey: propertyKey,
        apiUrl: apiUrl,
        noticeVersion: noticeVersion,
        categoryCodes: categoryCodes,
      );

  Map<String, Object?> toJson() => {
        'cookieConsents': cookieConsents,
        'marketingConsents': marketingConsents,
        'attempts': attempts,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'subjectId': subjectId,
        'propertyKey': propertyKey,
        'apiUrl': apiUrl,
        'noticeVersion': noticeVersion,
        'categoryCodes': categoryCodes,
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
      noticeVersion: asIntOrNull(map['noticeVersion']),
      categoryCodes: asStringList(map['categoryCodes']),
    );
  }
}

/// A refusal that resending the same decision cannot change. No answer, a 5xx,
/// a 429 or a challenge left unanswered may go through later.
bool isFinalStatus(int? statusCode) =>
    statusCode == 400 ||
    statusCode == 403 ||
    statusCode == 404 ||
    statusCode == 409 ||
    statusCode == 422;
