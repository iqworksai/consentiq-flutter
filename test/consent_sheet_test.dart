import 'package:consentiq/consentiq.dart';
import 'package:consentiq/src/consent_sheet.dart'
    show isLightHex, tryParseHexColor;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Future<ConsentIQ> pumpApp(
  WidgetTester tester, {
  FakeServer? server,
  ConsentIQConfig options = const ConsentIQConfig(propertyKey: testPropertyKey),
}) async {
  final fake = server ?? FakeServer();
  final consentIQ = ConsentIQ(
    options,
    apiClient: ConsentIQApiClient(
      propertyKey: options.propertyKey,
      apiUrl: testApiUrl,
      client: fake.client,
    ),
    storage: ConsentStorage(),
  );
  await tester.pumpWidget(
    ConsentIQProvider(
      consentIQ: consentIQ,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const ConsentSheet(),
              ConsentGate(
                category: 'analytics',
                placeholder: const Text('analytics off'),
                child: const Text('analytics on'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await consentIQ.init();
  await tester.pumpAndSettle();
  return consentIQ;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('noticeUriWithLanguage', () {
    test('appends lang with ? or & and keeps the fragment', () {
      expect(
        noticeUriWithLanguage('https://x.test/notice', 'en').toString(),
        'https://x.test/notice?lang=en',
      );
      expect(
        noticeUriWithLanguage('https://x.test/n?notice=1', 'ar-EG').toString(),
        'https://x.test/n?notice=1&lang=ar-EG',
      );
      expect(
        noticeUriWithLanguage('https://x.test/n?a=1#top', 'hi').toString(),
        'https://x.test/n?a=1&lang=hi#top',
      );
      expect(noticeUriWithLanguage(null, 'en'), isNull);
      expect(noticeUriWithLanguage('/relative', 'en'), isNull);
      expect(noticeUriWithLanguage('javascript:alert(1)', 'en'), isNull);
    });
  });

  group('banner colors', () {
    test('parses tolerantly and accepts only #rgb or #rrggbb', () {
      final banner = PropertyConfig.fromJson(configJson(
        bannerBgColor: '#0f172a',
        bannerTextColor: '#fff',
      )).banner;
      expect(banner.bannerBgColor, '#0f172a');
      expect(banner.bannerTextColor, '#fff');
      final old = PropertyConfig.fromJson(configJson()).banner;
      expect(old.bannerBgColor, isNull);
      expect(
        BannerConfig.fromJson(
            {'bannerBgColor': 12, 'bannerTextColor': <Object>[]}).bannerBgColor,
        isNull,
      );

      expect(tryParseHexColor('#0f172a'), const Color(0xFF0F172A));
      expect(tryParseHexColor(' #FFF '), const Color(0xFFFFFFFF));
      for (final bad in [
        null,
        '',
        'red',
        '0f172a',
        '#12345',
        '#ggg',
        '#1234'
      ]) {
        expect(tryParseHexColor(bad), isNull, reason: bad);
        expect(isLightHex(bad), isNull, reason: bad);
      }
    });

    test('light or dark by YIQ brightness, light at 150', () {
      expect(isLightHex('#fff'), isTrue);
      expect(isLightHex('#000000'), isFalse);
      // YIQ 150 exactly, and just below it.
      expect(isLightHex('#969696'), isTrue);
      expect(isLightHex('#959595'), isFalse);
      // Pure green is 149.7, so dark; yellow is 225.9.
      expect(isLightHex('#00ff00'), isFalse);
      expect(isLightHex('#ffff00'), isTrue);
      expect(isLightHex('#ff0000'), isFalse);
      expect(isLightHex('#e11d48'), isFalse);
    });
  });

  group('ConsentSheet', () {
    Color? colorOf(WidgetTester tester, String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    testWidgets('uses the dashboard background and text colors',
        (tester) async {
      await pumpApp(
        tester,
        server: FakeServer(
          config: configJson(
            bannerBgColor: '#0f172a',
            bannerTextColor: '#fafafa',
          ),
        ),
      );

      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        const Color(0xFF0F172A),
      );
      expect(colorOf(tester, 'We value your privacy'), const Color(0xFFFAFAFA));
      expect(
        colorOf(tester, 'We use cookies to improve your experience.'),
        const Color(0xFFD1D5DB),
      );
    });

    testWidgets('secondary and default text follow a light background',
        (tester) async {
      await pumpApp(
        tester,
        server: FakeServer(config: configJson(bannerBgColor: '#fff')),
      );

      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        const Color(0xFFFFFFFF),
      );
      expect(colorOf(tester, 'We value your privacy'), const Color(0xFF111827));
      expect(
        colorOf(tester, 'We use cookies to improve your experience.'),
        const Color(0xFF4B5563),
      );
    });

    testWidgets('absent or invalid colors keep the app theme', (tester) async {
      await pumpApp(tester);
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      final title = colorOf(tester, 'We value your privacy');
      expect(sheet.backgroundColor, isNot(const Color(0xFF0F172A)));

      await tester.pumpWidget(const SizedBox());
      await pumpApp(
        tester,
        server: FakeServer(
          config: configJson(bannerBgColor: 'navy', bannerTextColor: '#12345'),
        ),
      );
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        sheet.backgroundColor,
      );
      expect(colorOf(tester, 'We value your privacy'), title);
    });

    testWidgets('renders labels, blurb and notice link from config',
        (tester) async {
      await pumpApp(tester);

      expect(find.text('We value your privacy'), findsOneWidget);
      expect(
        find.text('We use cookies to improve your experience.'),
        findsOneWidget,
      );
      expect(find.text('View cookie notice'), findsOneWidget);
      expect(find.text('Accept all'), findsOneWidget);
      expect(find.text('Reject all'), findsOneWidget);
      expect(find.text('Customize'), findsOneWidget);
      expect(find.text('Save preferences'), findsNothing);
      expect(
        Directionality.of(tester.element(find.text('We value your privacy'))),
        TextDirection.ltr,
      );
      final buttonTheme = Theme.of(
        tester.element(find.byType(FilledButton)),
      ).filledButtonTheme;
      expect(
        buttonTheme.style?.backgroundColor?.resolve({}),
        const Color(0xFF123456),
      );
    });

    testWidgets('skips blurb and notice link when absent', (tester) async {
      await pumpApp(
        tester,
        server: FakeServer(
          config: configJson(noticeUrl: null, bannerDescription: null),
        ),
      );

      expect(find.text('We value your privacy'), findsOneWidget);
      expect(find.text('View cookie notice'), findsNothing);
      expect(
        find.text('We use cookies to improve your experience.'),
        findsNothing,
      );
    });

    testWidgets('flips to RTL for ar', (tester) async {
      await pumpApp(
        tester,
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          language: 'ar',
        ),
      );

      expect(find.text('نحن نحترم خصوصيتك'), findsOneWidget);
      expect(find.text('قبول الكل'), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.text('نحن نحترم خصوصيتك'))),
        TextDirection.rtl,
      );
    });

    testWidgets('Accept all closes the sheet, posts and opens the gate',
        (tester) async {
      final server = FakeServer();
      final consentIQ = await pumpApp(tester, server: server);
      expect(find.text('analytics off'), findsOneWidget);

      await tester.tap(find.text('Accept all'));
      await tester.pumpAndSettle();

      expect(find.text('We value your privacy'), findsNothing);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(server.submits, hasLength(1));
      expect(find.text('analytics on'), findsOneWidget);
    });

    testWidgets('Customize lists categories and Save commits the switches',
        (tester) async {
      final server = FakeServer();
      ConsentSaveEvent? saved;
      final consentIQ = await pumpApp(
        tester,
        server: server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onSave: (e) => saved = e,
        ),
      );

      await tester.tap(find.text('Customize'));
      await tester.pumpAndSettle();

      expect(find.text('Analytics cookies'), findsOneWidget);
      expect(find.text('Help us understand usage.'), findsOneWidget);
      expect(find.text('Necessary'), findsOneWidget);
      expect(find.text('Marketing'), findsOneWidget);
      expect(find.text('Save preferences'), findsOneWidget);
      expect(find.text('Accept all'), findsNothing);

      final tiles = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(tiles, hasLength(3));
      expect(tiles[0].value, isTrue);
      expect(tiles[0].onChanged, isNull);
      expect(tiles[1].value, isFalse);
      expect(tiles[1].onChanged, isNotNull);

      await tester.tap(find.byType(SwitchListTile).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save preferences'));
      await tester.pumpAndSettle();

      expect(consentIQ.isSheetVisible, isFalse);
      expect(find.text('Save preferences'), findsNothing);
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.hasConsent('marketing'), isFalse);
      expect(saved?.consent['analytics'], isTrue);
      expect(server.submits.single.json['cookieConsents'], {
        'necessary': true,
        'analytics': true,
        'marketing': false,
        'preferences': false,
        'social': false,
      });
    });

    testWidgets('backing out fires onClose and clears the flag',
        (tester) async {
      var closed = 0;
      final consentIQ = await pumpApp(
        tester,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onClose: () => closed++,
        ),
      );

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      await navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('We value your privacy'), findsNothing);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(closed, 1);
    });

    testWidgets('hideSheet closes without onClose; showSheet reopens',
        (tester) async {
      var closed = 0;
      var opened = 0;
      final consentIQ = await pumpApp(
        tester,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onClose: () => closed++,
          onOpen: () => opened++,
        ),
      );
      expect(opened, 1);

      consentIQ.hideSheet();
      await tester.pumpAndSettle();
      expect(find.text('We value your privacy'), findsNothing);
      expect(closed, 0);

      consentIQ.showSheet();
      await tester.pumpAndSettle();
      expect(find.text('We value your privacy'), findsOneWidget);
      expect(opened, 2);

      await tester.tap(find.text('Reject all'));
      await tester.pumpAndSettle();
      expect(find.text('We value your privacy'), findsNothing);
      expect(closed, 0);
    });

    testWidgets('stays hidden when consent already exists', (tester) async {
      await pumpApp(tester, server: FakeServer(consent: savedConsentJson()));

      expect(find.text('We value your privacy'), findsNothing);
      expect(find.text('analytics on'), findsOneWidget);
    });
  });
}
