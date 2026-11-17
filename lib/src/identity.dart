/// The subject to send and the identity token to send with it. A token is
/// signed over one exact identifier, and ConsentIQ verifies it against the
/// subject as sent, so when the submitted identifier is the signed one written
/// differently (an email's case, a phone's spacing) the signed form goes
/// instead. Any other identifier goes unsigned. The server is the judge.
({String subjectId, String? identityToken}) signedSubject(
  String? identityToken,
  String? identityFor,
  String identifier,
) {
  if (identityToken == null || identityToken.isEmpty) {
    return (subjectId: identifier, identityToken: null);
  }
  if (identityFor == null) {
    return (subjectId: identifier, identityToken: identityToken);
  }
  return sameIdentifier(identityFor, identifier)
      ? (subjectId: identityFor, identityToken: identityToken)
      : (subjectId: identifier, identityToken: null);
}

/// Whether two identifiers name the same person: emails by case, phones by
/// their digits once both read as one (an optional leading plus, then digits
/// with spaces, dots, dashes or brackets). Anything else must match exactly,
/// so two names never collapse to the same empty digit string.
bool sameIdentifier(String first, String second) {
  final lhs = first.trim();
  final rhs = second.trim();
  if (lhs.contains('@') || rhs.contains('@')) {
    return lhs.toLowerCase() == rhs.toLowerCase();
  }
  final lhsDigits = _phoneDigits(lhs);
  final rhsDigits = _phoneDigits(rhs);
  return lhsDigits != null && rhsDigits != null
      ? lhsDigits == rhsDigits
      : lhs == rhs;
}

final RegExp _phoneShape = RegExp(r'^\+?[\d\s().-]+$');
final RegExp _phoneSeparators = RegExp(r'[\s().-]');
final RegExp _phoneDigitsOnly = RegExp(r'^\+?\d{7,15}$');

String? _phoneDigits(String value) {
  if (!_phoneShape.hasMatch(value)) return null;
  final digits = value.replaceAll(_phoneSeparators, '');
  return _phoneDigitsOnly.hasMatch(digits) ? digits : null;
}
