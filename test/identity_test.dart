import 'package:consentiq/src/identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('emails compare by case', () {
    expect(sameIdentifier('Alice@Example.com', ' alice@example.com '), isTrue);
    expect(sameIdentifier('alice@example.com', 'bob@example.com'), isFalse);
  });

  test('phones compare by digits only when both read as phones', () {
    expect(sameIdentifier('+1 (202) 555-0143', '+12025550143'), isTrue);
    expect(sameIdentifier('+12025550143', '+12025550144'), isFalse);
  });

  test('anything else must match exactly', () {
    expect(sameIdentifier('alice', 'bob'), isFalse);
    expect(sameIdentifier('user-1', 'User-1'), isFalse);
    expect(sameIdentifier('user-1', 'user-1'), isTrue);
  });

  test('without identityFor the token goes as is', () {
    final signed = signedSubject('v2.1.sig', null, 'user-1');
    expect(signed.subjectId, 'user-1');
    expect(signed.identityToken, 'v2.1.sig');
  });
}
