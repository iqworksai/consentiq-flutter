import 'package:consentiq/consentiq.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ConsentStorage', () {
    test('round-trips the consent cache under consentiq_consent', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = ConsentStorage();

      expect(await storage.loadConsent(), isNull);

      await storage.saveConsent({'necessary': false, 'analytics': true});

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_consent'), isNotNull);
      expect(await storage.loadConsent(), {
        'necessary': true,
        'analytics': true,
      });
    });

    test('ignores a corrupt cache', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_consent': 'not json',
      });

      expect(await ConsentStorage().loadConsent(), isNull);
    });

    test('generates a v4 subject id once and persists it', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = ConsentStorage();

      final first = await storage.getOrCreateSubjectId();
      final second = await storage.getOrCreateSubjectId();

      expect(first, second);
      expect(
        first,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_subject_id'), first);
    });

    test('reuses a stored subject id', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'existing-id',
      });

      expect(await ConsentStorage().getOrCreateSubjectId(), 'existing-id');
    });

    test('clearConsent keeps the subject id, clearAll removes both', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_subject_id': 'existing-id',
        'consentiq_consent': '{"necessary":true}',
      });
      final storage = ConsentStorage();

      await storage.clearConsent();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_consent'), isNull);
      expect(prefs.getString('consentiq_subject_id'), 'existing-id');

      await storage.clearAll();
      expect(prefs.getString('consentiq_subject_id'), isNull);
    });

    test('accepts an injected SharedPreferences instance', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = ConsentStorage(preferences: prefs);

      await storage.saveSubjectId('injected');

      expect(prefs.getString('consentiq_subject_id'), 'injected');
      expect(await storage.loadSubjectId(), 'injected');
    });
  });
}
