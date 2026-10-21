import 'dart:convert';

import 'package:consentiq/consentiq.dart';
import 'package:consentiq/src/captcha.dart';
import 'package:consentiq/src/consent_iq.dart' show tcfSessionOf;
import 'package:consentiq/src/tcf.dart';
import 'package:consentiq/src/tcf_key_store.dart';
import 'package:consentiq/src/web_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'fake_webview.dart';
import 'fixtures.dart';

final Uri tcfUrl =
    Uri.parse('$testApiUrl/api/public/tcf/mobile?key=$testPropertyKey');

const MethodChannel keyChannel = MethodChannel(tcfKeyChannel);

/// Plays the native side of the key channel, keeping what it was told to
/// write so a test can check types as well as values.
class FakeKeyStore {
  final List<Map<String, dynamic>> calls = [];
  final Map<String, Object> store = {};

  /// Fails, as a broken plugin would, any call this returns true for.
  bool Function(Map<String, dynamic> args)? failWhen;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keyChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      calls.add({'method': call.method, ...args});
      if (failWhen?.call(args) ?? false) {
        throw PlatformException(code: 'broken');
      }
      for (final key in (args['remove'] as List).cast<String>()) {
        store.remove(key);
      }
      (args['ints'] as Map).forEach((k, v) => store[k as String] = v as int);
      (args['strings'] as Map)
          .forEach((k, v) => store[k as String] = v as String);
      return null;
    });
  }
}

Map<String, Object> decisionKeys({bool withRestriction = true}) => {
      'IABTCF_CmpSdkID': 300,
      'IABTCF_CmpSdkVersion': 1,
      'IABTCF_PolicyVersion': 5,
      'IABTCF_gdprApplies': 1,
      'IABTCF_PublisherCC': 'DE',
      'IABTCF_PurposeOneTreatment': 0,
      'IABTCF_UseNonStandardTexts': 0,
      'IABTCF_TCString': 'CQ-tc-string',
      'IABTCF_VendorConsents': '0100',
      'IABTCF_PurposeConsents': '1100000000',
      if (withRestriction) 'IABTCF_PublisherRestrictions2': '0001',
    };

const Map<String, Object> storedRecord = {
  'tcString': 'CQ-tc-string',
  'vendorIds': [1, 2, 755],
  'restrictionsKey': '2:1:755',
};

Map<String, Object?> decisionMessage({
  Map<String, bool> consent = const {
    'necessary': true,
    'analytics': true,
    'marketing': false,
  },
  String? scope = 'custom',
}) =>
    {
      'type': 'decision',
      'tcString': 'CQ-tc-string',
      'keys': decisionKeys(),
      'stored': storedRecord,
      'consent': consent,
      if (scope != null) 'scope': scope,
    };

Map<String, dynamic> startOptions(String script) {
  const prefix = 'window.consentiqTcfStart(';
  expect(script, startsWith(prefix));
  expect(script, endsWith(')'));
  return jsonDecode(script.substring(prefix.length, script.length - 1))
      as Map<String, dynamic>;
}

extension on FakeWebViewController {
  String? get runToken =>
      scripts.isEmpty ? null : startOptions(scripts.last)['token'] as String?;

  /// Posts [message] as the started page does, echoing the run's token.
  void answer(Map<String, Object?> message) =>
      post({...message, 'token': runToken});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebViewPlatform platform;
  late FakeKeyStore keys;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    WebViewPlatform.instance = platform = FakeWebViewPlatform();
    CaptchaController.resetForTesting();
    keys = FakeKeyStore()..install();
  });

  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(keyChannel, null));

  ConsentIQ build(
    FakeServer server, {
    ConsentIQConfig options = const ConsentIQConfig(
      propertyKey: testPropertyKey,
      apiUrl: testApiUrl,
    ),
  }) =>
      ConsentIQ(
        options,
        apiClient: ConsentIQApiClient(
          propertyKey: options.propertyKey,
          apiUrl: testApiUrl,
          client: server.client,
        ),
        storage: ConsentStorage(),
      );

  FakeServer tcfServer({Map<String, dynamic>? tcf}) =>
      FakeServer(config: configJson(tcf: tcf ?? tcfJson()));

  group('TcfKeyStore', () {
    test('writes numbers as ints and strings as strings', () async {
      await const TcfKeyStore().write({
        ...decisionKeys(),
        'IABTCF_Fraction': 2.0,
        'IABTCF_Flag': true,
        'IABTCF_Nothing': null,
        'unrelated_app_setting': 'x',
      });

      final call = keys.calls.single;
      expect(call['method'], 'update');
      final ints = call['ints'] as Map;
      final strings = call['strings'] as Map;
      expect(ints['IABTCF_gdprApplies'], isA<int>());
      expect(ints['IABTCF_gdprApplies'], 1);
      expect(ints['IABTCF_PolicyVersion'], 5);
      expect(ints.containsKey('IABTCF_CmpSdkID'), isFalse);
      expect(ints.containsKey('IABTCF_CmpSdkVersion'), isFalse);
      expect(ints['IABTCF_PurposeOneTreatment'], 0);
      expect(ints['IABTCF_Fraction'], 2);
      expect(ints['IABTCF_Flag'], 1);
      expect(strings['IABTCF_TCString'], 'CQ-tc-string');
      expect(strings['IABTCF_PurposeConsents'], '1100000000');
      expect(strings['IABTCF_PublisherCC'], 'DE');
      expect(ints.keys.toSet().intersection(strings.keys.toSet()), isEmpty);
      expect(ints.containsKey('IABTCF_Nothing'), isFalse);
      expect(strings.containsKey('IABTCF_Nothing'), isFalse);
      expect(strings.containsKey('unrelated_app_setting'), isFalse);
    });

    test('removes every decision key the new decision lacks', () async {
      keys.store.addAll({
        'IABTCF_CmpSdkID': 300,
        'IABTCF_CmpSdkVersion': 1,
        'IABTCF_SpecialFeaturesOptIns': '11',
        'IABTCF_PublisherRestrictions5': '01',
      });
      await const TcfKeyStore().write(decisionKeys());
      final written = decisionKeys().keys.toSet();
      expect(keys.calls.single['remove'], [
        for (final key in tcfDecisionKeys)
          if (!written.contains(key)) key,
      ]);
      expect(keys.calls.single['remove'],
          contains('IABTCF_PublisherRestrictions5'));
      expect(keys.calls.single['remove'], isNot(contains('IABTCF_CmpSdkID')));
      expect(keys.store['IABTCF_PublisherRestrictions2'], '0001');
      expect(keys.store.containsKey('IABTCF_SpecialFeaturesOptIns'), isFalse);
      expect(keys.store.containsKey('IABTCF_PublisherRestrictions5'), isFalse);
      expect(keys.store['IABTCF_CmpSdkID'], 300);
      expect(keys.store['IABTCF_CmpSdkVersion'], 1);

      await const TcfKeyStore().write(decisionKeys(withRestriction: false));
      expect(keys.store.containsKey('IABTCF_PublisherRestrictions2'), isFalse);
    });

    test('writeGdprApplies and writeCmp write ints only', () async {
      await const TcfKeyStore().writeGdprApplies(false);
      await const TcfKeyStore().writeGdprApplies(true);
      await const TcfKeyStore().writeCmp(cmpId: 300, cmpVersion: 2);

      expect(keys.calls.map((c) => c['ints']), [
        {'IABTCF_gdprApplies': 0},
        {'IABTCF_gdprApplies': 1},
        {'IABTCF_CmpSdkID': 300, 'IABTCF_CmpSdkVersion': 2},
      ]);
      expect(keys.calls.map((c) => c['strings']), everyElement(isEmpty));
      expect(keys.calls.map((c) => c['remove']), everyElement(isEmpty));
    });
  });

  group('clearing a decision', () {
    Map<String, Object> fullStore() => {
          ...decisionKeys(),
          'IABTCF_VendorLegitimateInterests': '0000',
          'IABTCF_DisclosedVendors': '1111',
          'IABTCF_PurposeLegitimateInterests': '0100000000',
          'IABTCF_SpecialFeaturesOptIns': '00',
          'IABTCF_PublisherConsent': '0',
          'IABTCF_PublisherLegitimateInterests': '0',
          'IABTCF_PublisherCustomPurposesConsents': '',
          'IABTCF_PublisherCustomPurposesLegitimateInterests': '',
          for (var id = 1; id <= 11; id++)
            'IABTCF_PublisherRestrictions$id': '01',
        };
    const kept = {
      'IABTCF_CmpSdkID': 300,
      'IABTCF_CmpSdkVersion': 1,
      'IABTCF_gdprApplies': 1,
    };

    test('clearDecision removes every decision key and keeps the CMP ones',
        () async {
      keys.store.addAll(fullStore());
      await const TcfKeyStore().clearDecision();
      expect(keys.calls.single['ints'], isEmpty);
      expect(keys.calls.single['strings'], isEmpty);
      expect(keys.calls.single['remove'], hasLength(26));
      expect(keys.store, kept);
    });

    test('resetConsent clears the keys this SDK wrote', () async {
      final consentIQ = build(tcfServer());
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.answer({'type': 'show'});
      await pumpEventQueue();
      web.answer(decisionMessage());
      await pumpEventQueue();
      keys.store.addAll(fullStore());

      await consentIQ.resetConsent();
      expect(keys.store, kept);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_tcf'), isNull);
    });

    test('resetConsent never touches another CMP\'s keys', () async {
      keys.store.addAll(fullStore());
      final consentIQ = build(FakeServer());
      await consentIQ.init();
      await consentIQ.resetConsent();
      expect(keys.calls, isEmpty);
      expect(keys.store, fullStore());
    });

    for (final (label, tcf) in [
      ('absent', null),
      ('disabled', tcfJson(enabled: false)),
      ('cmpId below 2', tcfJson(cmpId: 0)),
    ]) {
      test('TCF $label after this SDK wrote keys: all of them removed',
          () async {
        SharedPreferences.setMockInitialValues({
          'consentiq_tcf_cmp': true,
          'consentiq_tcf': jsonEncode(storedRecord),
        });
        keys.store.addAll({...fullStore(), ...kept, 'IABTCF_Other': 'x'});
        final consentIQ = build(FakeServer(config: configJson(tcf: tcf)));
        await consentIQ.init();

        expect(keys.store, {'IABTCF_Other': 'x'});
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('consentiq_tcf_cmp'), isNull);
        expect(prefs.getString('consentiq_tcf'), isNull);
        expect(consentIQ.isSheetVisible, isTrue);
      });
    }

    test('TCF off without the marker: another CMP\'s keys untouched', () async {
      keys.store.addAll({...fullStore(), ...kept});
      final consentIQ = build(FakeServer());
      await consentIQ.init();
      expect(keys.calls, isEmpty);
      expect(keys.store, {...fullStore(), ...kept});
    });

    test('resetConsent with the marker clears decision keys with TCF off',
        () async {
      final consentIQ = build(FakeServer());
      await consentIQ.init();
      SharedPreferences.setMockInitialValues({'consentiq_tcf_cmp': true});
      keys.store.addAll({...fullStore(), ...kept});
      final reset = build(FakeServer());
      await reset.resetConsent();
      expect(keys.store, kept);
      expect(consentIQ.isTcfActive, isFalse);
    });

    test('a consent the server reports expired clears the keys too', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf_cmp': true,
        'consentiq_subject_id': 'sid-1',
        'consentiq_tcf': jsonEncode(storedRecord),
      });
      keys.store.addAll(fullStore());
      final consentIQ = build(FakeServer(
        config: configJson(tcf: tcfJson()),
        consent: const {'consent': null, 'expired': true},
      ));
      await consentIQ.init();
      await pumpEventQueue();

      expect(keys.store, kept);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_tcf'), isNull);
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(startOptions(web.scripts.single)['stored'], isNull);
    });
  });

  group('TcfSettings', () {
    test('parses the config block and gates on enabled and cmpId', () {
      final config = PropertyConfig.fromJson(configJson(tcf: tcfJson()));
      final tcf = config.tcf!;
      expect(tcf.enabled, isTrue);
      expect(tcf.gdprApplies, isTrue);
      expect(tcf.vendorIds, [1, 2, 755]);
      expect(tcf.publisherCountryCode, 'DE');
      expect(tcf.publisherRestrictions.single.purposeId, 2);
      expect(tcf.publisherRestrictions.single.restrictionType, 1);
      expect(tcf.publisherRestrictions.single.vendorIds, [755]);
      expect(tcf.repromptMonths, 13);
      expect(tcf.tcfPolicyVersion, 5);
      expect(tcf.cmpId, 300);
      expect(tcf.cmpVersion, 1);
      expect(
        tcf.vendorListUrl,
        '/api/public/tcf/$testPropertyKey/vendor-list?v=abc',
      );
      expect(tcf.isActive, isTrue);

      expect(TcfSettings.fromJson(tcfJson(cmpId: 0)).isActive, isFalse);
      expect(TcfSettings.fromJson(tcfJson(cmpId: 1)).isActive, isFalse);
      expect(TcfSettings.fromJson(tcfJson(cmpId: 2)).isActive, isTrue);
      expect(TcfSettings.fromJson(tcfJson(enabled: false)).isActive, isFalse);
    });

    test('tolerates a missing or malformed block', () {
      expect(PropertyConfig.fromJson(configJson()).tcf, isNull);
      expect(
        PropertyConfig.fromJson({...configJson(), 'tcf': 'yes'}).tcf,
        isNull,
      );
      final odd = TcfSettings.fromJson({
        'enabled': 'true',
        'vendorIds': [1, 'two', 3.0],
        'publisherRestrictions': 'none',
        'tcfPolicyVersion': null,
        'cmpId': '300',
      });
      expect(odd.enabled, isFalse);
      expect(odd.gdprApplies, isTrue);
      expect(odd.vendorIds, [1, 3]);
      expect(odd.publisherRestrictions, isEmpty);
      expect(odd.tcfPolicyVersion, isNull);
      expect(odd.cmpId, 0);
      expect(odd.isActive, isFalse);
    });
  });

  group('parseTcfMessage', () {
    const t = 'run-token';
    String m(Map<String, Object?> data) => jsonEncode({...data, 'token': t});
    TcfMessage? parse(Map<String, Object?> data) =>
        parseTcfMessage(m(data), token: t);

    test('reads every message type', () {
      expect(parse({'type': 'ready'}), isA<TcfReady>());
      expect(parse({'type': 'current'}), isA<TcfCurrent>());
      expect(parse({'type': 'show'}), isA<TcfShow>());
      expect(parse({'type': 'not-applicable'}), isA<TcfNotApplicable>());
      expect(parse({'type': 'closed'}), isA<TcfClosed>());
      expect(
        parse({'type': 'error', 'code': 'no-cmp-id'}),
        isA<TcfError>().having((e) => e.code, 'code', 'no-cmp-id'),
      );
      expect(
        parse({'type': 'error'}),
        isA<TcfError>().having((e) => e.code, 'code', 'error'),
      );

      final decision = parse(decisionMessage());
      expect(decision, isA<TcfDecision>());
      decision as TcfDecision;
      expect(decision.tcString, 'CQ-tc-string');
      expect(decision.keys['IABTCF_TCString'], 'CQ-tc-string');
      expect(decision.stored, storedRecord);
      expect(decision.consent, {
        'necessary': true,
        'analytics': true,
        'marketing': false,
      });
      expect(decision.scope, 'custom');
      for (final scope in [null, 'bogus']) {
        final parsed = parse(decisionMessage(scope: scope));
        expect((parsed as TcfDecision).scope, isNull, reason: scope);
      }
    });

    test('after start only messages echoing the run token count', () {
      for (final token in [null, 'other-token', 7]) {
        final raw = jsonEncode({'type': 'show', 'token': token});
        expect(parseTcfMessage(raw, token: t), isNull, reason: '$token');
      }
      expect(
        parseTcfMessage(jsonEncode(decisionMessage()), token: t),
        isNull,
      );
    });

    test('before start only ready counts', () {
      expect(
        parseTcfMessage(jsonEncode({'type': 'ready'}), token: null),
        isA<TcfReady>(),
      );
      for (final type in ['show', 'current', 'closed', 'error', 'decision']) {
        expect(
          parseTcfMessage(jsonEncode({'type': type, 'token': t}), token: null),
          isNull,
          reason: type,
        );
      }
    });

    test('a decision without keys or stored is an error', () {
      expect(
        parse({'type': 'decision', 'stored': <String, Object>{}}),
        isA<TcfError>().having((e) => e.code, 'code', 'invalid-decision'),
      );
      expect(
        parse({'type': 'decision', 'keys': decisionKeys()}),
        isA<TcfError>(),
      );
    });

    test('ignores malformed and unknown messages', () {
      expect(parseTcfMessage('not json', token: t), isNull);
      expect(parseTcfMessage('[1, 2]', token: t), isNull);
      expect(parse({'type': 'token'}), isNull);
      expect(parse({'kind': 'show'}), isNull);
    });
  });

  group('isHostedPage', () {
    test('matches scheme, host, port and path only', () {
      expect(isHostedPage(tcfUrl.toString(), tcfUrl), isTrue);
      expect(isHostedPage('$testApiUrl/api/public/tcf/mobile', tcfUrl), isTrue);
      for (final url in [
        null,
        '',
        'about:blank',
        'http://consent.example.test/api/public/tcf/mobile?key=pk',
        'https://consent.example.test:8443/api/public/tcf/mobile',
        'https://evil.test/api/public/tcf/mobile?key=pk',
        'https://consent.example.test.evil.test/api/public/tcf/mobile',
        '$testApiUrl/api/public/tcf/mobile/x',
        '$testApiUrl/api/public/captcha/mobile',
      ]) {
        expect(isHostedPage(url, tcfUrl), isFalse, reason: url);
      }
    });
  });

  group('TcfSession', () {
    test('drops messages unless the page is the hosted TCF page', () async {
      final messages = <TcfMessage>[];
      final session = TcfSession(pageUrl: tcfUrl, onMessage: messages.add);
      await session.open();
      final web = platform.controllers.single;
      var ready = false;
      session.ready.then((_) => ready = true).ignore();

      web.pageUrl = 'https://evil.test/api/public/tcf/mobile?key=pk';
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(ready, isFalse);

      web.pageUrl = null;
      web.post({'type': 'show', 'token': session.token});
      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(ready, isTrue);
      expect(messages, isEmpty, reason: 'nothing but ready before start');

      await session.start(subjectId: 's', stored: null, consent: null);
      expect(startOptions(web.scripts.single)['token'], session.token);
      web.post({'type': 'show'});
      web.post({'type': 'show', 'token': 'guessed'});
      web.pageUrl = 'https://evil.test/api/public/tcf/mobile?key=pk';
      web.answer({'type': 'show'});
      await pumpEventQueue();
      expect(messages, isEmpty);

      web.pageUrl = null;
      web.answer({'type': 'show'});
      await pumpEventQueue();
      expect(messages.single, isA<TcfShow>());
      session.release();
    });

    test('each run has its own unguessable token', () {
      final tokens = {for (var i = 0; i < 20; i++) newTcfToken()};
      expect(tokens, hasLength(20));
      expect(tokens, everyElement(matches(RegExp(r'^[0-9a-f]{32}$'))));
    });

    test('navigation: the page itself, Turnstile frames, links outside',
        () async {
      final opened = <Uri>[];
      final session = TcfSession(
        pageUrl: tcfUrl,
        onMessage: (_) {},
        openExternal: (uri) async => opened.add(uri),
      );
      await session.open();
      final decide = platform.controllers.single.delegate!.onNavigationRequest!;
      Future<NavigationDecision> check(String url, {bool main = true}) async =>
          decide(NavigationRequest(url: url, isMainFrame: main));

      expect(await check(tcfUrl.toString()), NavigationDecision.navigate);
      expect(
        await check('https://challenges.cloudflare.com/x', main: false),
        NavigationDecision.navigate,
      );
      expect(
        await check('https://vendor.test/privacy'),
        NavigationDecision.prevent,
      );
      expect(opened, isEmpty, reason: 'nothing opens while hidden');

      session.present();
      expect(
        await check('https://vendor.test/privacy'),
        NavigationDecision.prevent,
      );
      expect(
        await check('https://vendor.test/claim', main: false),
        NavigationDecision.prevent,
      );
      expect(await check('intent://x'), NavigationDecision.prevent);
      expect(opened, [Uri.parse('https://vendor.test/privacy')],
          reason: 'a subframe navigation never opens the browser');
    });
  });

  group('ConsentIQ in TCF mode', () {
    test('cmpId below 2: no TCF at all, the sheet as before', () async {
      final consentIQ = build(tcfServer(tcf: tcfJson(cmpId: 0)));
      await consentIQ.init();
      await pumpEventQueue();

      expect(consentIQ.isTcfActive, isFalse);
      expect(consentIQ.isSheetVisible, isTrue);
      expect(platform.controllers, isEmpty);
      expect(keys.calls, isEmpty);
    });

    test('gdprApplies false: CMP keys and gdprApplies 0, then the sheet',
        () async {
      final consentIQ = build(tcfServer(tcf: tcfJson(gdprApplies: false)));
      await consentIQ.init();
      await pumpEventQueue();

      expect(keys.store, {
        'IABTCF_CmpSdkID': 300,
        'IABTCF_CmpSdkVersion': 1,
        'IABTCF_gdprApplies': 0,
      });
      expect(consentIQ.isTcfActive, isFalse);
      expect(consentIQ.isSheetVisible, isTrue);
      expect(platform.controllers, isEmpty);
    });

    test('prewarms the page hidden and starts it once ready', () async {
      final consentIQ = build(tcfServer());
      await consentIQ.init();
      await pumpEventQueue();

      expect(keys.store, {'IABTCF_CmpSdkID': 300, 'IABTCF_CmpSdkVersion': 1});
      expect(consentIQ.isTcfActive, isTrue);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(consentIQ.isTcfVisible, isFalse);
      final web = platform.controllers.single;
      expect(web.loads, [tcfUrl]);
      expect(web.channels.keys, ['ConsentIQFlutter']);
      expect(web.javaScriptMode, JavaScriptMode.unrestricted);
      expect(web.backgrounds, isNotEmpty);
      expect(HiddenWebViews.instance.controllers, hasLength(1));
      expect(web.scripts, isEmpty);

      web.post({'type': 'ready'});
      await pumpEventQueue();
      expect(startOptions(web.scripts.single), {
        'subjectId': consentIQ.subjectId,
        'stored': null,
        'consent': null,
        'reopen': false,
        'token': isA<String>(),
      });
    });

    test('current: gdprApplies 1, page released, no UI', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
        'consentiq_consent': jsonEncode({'necessary': true, 'analytics': true}),
      });
      var opened = 0;
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onOpen: () => opened++,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      final options = startOptions(web.scripts.single);
      expect(options['stored'], storedRecord);
      expect(options['consent'], containsPair('analytics', true));
      expect(options['reopen'], isFalse);

      web.answer({'type': 'current'});
      await pumpEventQueue();
      expect(keys.store['IABTCF_gdprApplies'], 1);
      expect(HiddenWebViews.instance.controllers, isEmpty);
      expect(tcfSessionOf(consentIQ), isNull);
      expect(consentIQ.isSheetVisible, isFalse);
      expect(opened, 0);
    });

    test('show then decision: keys, record and consent saved, no resubmit',
        () async {
      final server = tcfServer();
      final changes = <Map<String, bool>>[];
      final saves = <ConsentSaveEvent>[];
      var opened = 0;
      final consentIQ = build(
        server,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onOpen: () => opened++,
          onSave: saves.add,
          onConsentChange: (consent, _) => changes.add(consent),
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();

      web.answer({'type': 'show'});
      await pumpEventQueue();
      expect(consentIQ.isTcfVisible, isTrue);
      expect(opened, 1);
      expect(HiddenWebViews.instance.controllers, isEmpty);

      web.answer(decisionMessage());
      await pumpEventQueue();

      expect(keys.store['IABTCF_TCString'], 'CQ-tc-string');
      expect(keys.store['IABTCF_CmpSdkID'], 300);
      expect(keys.store['IABTCF_PublisherRestrictions2'], '0001');
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString('consentiq_tcf')!), storedRecord);
      expect(jsonDecode(prefs.getString('consentiq_consent')!),
          containsPair('analytics', true));
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.hasConsent('marketing'), isFalse);
      expect(consentIQ.isTcfVisible, isFalse);
      expect(tcfSessionOf(consentIQ), isNull);
      expect(saves.single.consent, containsPair('analytics', true));
      expect(changes.single, containsPair('analytics', true));
      expect(server.submits, isEmpty);
      expect(consentIQ.isSheetVisible, isFalse);
    });

    test('a decision fires onAccept, onReject or onSave by its scope',
        () async {
      const all = {'necessary': true, 'analytics': true, 'marketing': true};
      const none = {'necessary': true, 'analytics': false, 'marketing': false};
      const some = {'necessary': true, 'analytics': true, 'marketing': false};
      for (final (scope, consent, expected) in [
        ('all', some, 'accept'),
        ('none', some, 'reject'),
        ('custom', all, 'save'),
        (null, all, 'accept'),
        (null, none, 'reject'),
        (null, some, 'save'),
      ]) {
        SharedPreferences.setMockInitialValues({});
        final fired = <String>[];
        final consentIQ = build(
          tcfServer(),
          options: ConsentIQConfig(
            propertyKey: testPropertyKey,
            onAccept: (e) {
              expect(e.scope, ConsentScope.all);
              fired.add('accept');
            },
            onReject: (_) => fired.add('reject'),
            onSave: (_) => fired.add('save'),
            onConsentChange: (_, __) => fired.add('change'),
          ),
        );
        await consentIQ.init();
        await pumpEventQueue();
        final web = platform.controllers.last;
        web.post({'type': 'ready'});
        await pumpEventQueue();
        web.answer({'type': 'show'});
        await pumpEventQueue();
        web.answer(decisionMessage(scope: scope, consent: consent));
        await pumpEventQueue();
        expect(fired, [expected, 'change'], reason: '$scope $consent');
      }
    });

    test('mode is known before loading is announced as done', () async {
      final consentIQ = build(tcfServer());
      final seen = <(bool, bool)>[];
      consentIQ.addListener(
          () => seen.add((consentIQ.isLoading, consentIQ.isTcfActive)));
      await consentIQ.init();
      expect(seen.first, (false, true));
    });

    test('autoShow off: gdprApplies 1 from the config, no page', () async {
      final consentIQ = build(
        tcfServer(),
        options: const ConsentIQConfig(
          propertyKey: testPropertyKey,
          autoShow: false,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      expect(keys.store, {
        'IABTCF_CmpSdkID': 300,
        'IABTCF_CmpSdkVersion': 1,
        'IABTCF_gdprApplies': 1,
      });
      expect(platform.controllers, isEmpty);
      expect(consentIQ.isTcfActive, isTrue);
    });

    test('any successful IABTCF write marks the keys as this SDK\'s', () async {
      keys.failWhen = (args) => (args['ints'] as Map).containsKey(
            'IABTCF_CmpSdkID',
          );
      final consentIQ = build(tcfServer(tcf: tcfJson(gdprApplies: false)));
      await consentIQ.init();
      final prefs = await SharedPreferences.getInstance();
      expect(keys.store, {'IABTCF_gdprApplies': 0});
      expect(prefs.getBool('consentiq_tcf_cmp'), isTrue);
    });

    testWidgets('no answer within 45 s of start ends the run', (tester) async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await tester.pump();
      platform.controllers.single.post({'type': 'ready'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 44));
      expect(errors, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(errors.single.code, 'answer-timeout');
      expect(tcfSessionOf(consentIQ), isNull);
      expect(consentIQ.isSheetVisible, isTrue);
    });

    testWidgets('a shown page has no answer timeout', (tester) async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await tester.pump();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await tester.pump();
      web.answer({'type': 'show'});
      await tester.pump(const Duration(minutes: 5));
      expect(errors, isEmpty);
      expect(consentIQ.isTcfVisible, isTrue);
    });

    test('a decision whose keys fail to write keeps no stored record',
        () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode({'tcString': 'old'}),
      });
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.answer({'type': 'show'});
      await pumpEventQueue();
      keys.failWhen = (args) => (args['strings'] as Map).isNotEmpty;
      web.answer(decisionMessage());
      await pumpEventQueue();

      expect(errors.single.code, 'key-store');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_tcf'), isNull);
      expect(consentIQ.hasConsent('analytics'), isTrue);
      expect(consentIQ.isTcfVisible, isFalse);
    });

    test('tcf-off: owned keys and marker removed, never gdprApplies 0',
        () async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      keys.store.addAll({...decisionKeys(), 'IABTCF_Other': 'x'});
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.answer({'type': 'error', 'code': 'tcf-off'});
      await pumpEventQueue();

      expect(keys.store, {'IABTCF_Other': 'x'});
      expect(
        keys.calls.map((c) => (c['ints'] as Map)['IABTCF_gdprApplies']),
        isNot(contains(0)),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('consentiq_tcf_cmp'), isNull);
      expect(errors, isEmpty);
      expect(consentIQ.isTcfActive, isFalse);
      expect(consentIQ.isSheetVisible, isTrue);
    });

    test('a sheet decision after a failure clears the owned decision keys',
        () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
      });
      final server = tcfServer();
      final consentIQ = build(server);
      await consentIQ.init();
      await pumpEventQueue();
      keys.store.addAll(decisionKeys());
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.answer({'type': 'error', 'code': 'start-failed'});
      await pumpEventQueue();
      expect(consentIQ.isSheetVisible, isTrue);

      await consentIQ.rejectAll();
      expect(keys.store, {
        'IABTCF_CmpSdkID': 300,
        'IABTCF_CmpSdkVersion': 1,
        'IABTCF_gdprApplies': 1,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_tcf'), isNull);
      expect(server.submits, hasLength(1));
    });

    test('an open during the start-up check runs once that check ends',
        () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
        'consentiq_consent': jsonEncode({'necessary': true}),
      });
      final consentIQ = build(tcfServer());
      await consentIQ.init();
      await pumpEventQueue();
      consentIQ.showSheet();
      consentIQ.showTcfPreferences();
      await pumpEventQueue();
      expect(platform.controllers, hasLength(1));

      final first = platform.controllers.single;
      first.post({'type': 'ready'});
      await pumpEventQueue();
      first.answer({'type': 'current'});
      await pumpEventQueue();
      expect(platform.controllers, hasLength(2));
      final second = platform.controllers.last;
      second.post({'type': 'ready'});
      await pumpEventQueue();
      expect(startOptions(second.scripts.single)['reopen'], isTrue);
      expect(
        startOptions(second.scripts.single)['token'],
        isNot(startOptions(first.scripts.single)['token']),
      );
    });

    test('a queued open is spent when the first prompt shows', () async {
      final consentIQ = build(tcfServer());
      await consentIQ.init();
      await pumpEventQueue();
      consentIQ.showSheet();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();
      web.answer({'type': 'show'});
      await pumpEventQueue();
      web.answer(decisionMessage());
      await pumpEventQueue();
      expect(platform.controllers, hasLength(1));
      expect(tcfSessionOf(consentIQ), isNull);
    });

    test('not-applicable: gdprApplies 0 and the normal sheet', () async {
      final consentIQ = build(tcfServer());
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();

      web.answer({'type': 'not-applicable'});
      await pumpEventQueue();
      expect(keys.store['IABTCF_gdprApplies'], 0);
      expect(consentIQ.isTcfActive, isFalse);
      expect(consentIQ.isSheetVisible, isTrue);
      expect(HiddenWebViews.instance.controllers, isEmpty);
    });

    test('error: reported through onError, then the normal sheet', () async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      final web = platform.controllers.single;
      web.post({'type': 'ready'});
      await pumpEventQueue();

      final logs = await captureLogs(() async {
        web.answer({'type': 'error', 'code': 'no-cmp-id'});
        await pumpEventQueue();
      });
      expect(errors.single.source, 'tcf');
      expect(errors.single.code, 'no-cmp-id');
      expect(logs, ['[ConsentIQ] IAB TCF failed (no-cmp-id)']);
      expect(consentIQ.isSheetVisible, isTrue);
      expect(consentIQ.isTcfActive, isTrue, reason: 'a failure is transient');

      consentIQ.hideSheet();
      consentIQ.showSheet();
      await pumpEventQueue();
      expect(platform.controllers, hasLength(2));
      expect(consentIQ.isSheetVisible, isFalse);
    });

    test('a main-frame load failure is an error', () async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      platform.controllers.single.delegate!.onWebResourceError!(
        const WebResourceError(
            errorCode: -2, description: 'x', isForMainFrame: true),
      );
      await pumpEventQueue();
      expect(errors.single.code, 'load');
      expect(consentIQ.isSheetVisible, isTrue);
    });

    testWidgets('no ready within 15 s is a timeout', (tester) async {
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      await tester.pump(const Duration(seconds: 14));
      expect(errors, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(errors.single.code, 'timeout');
      expect(consentIQ.isSheetVisible, isTrue);
    });

    test('a missing native plugin is reported, never thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(keyChannel, null);
      final errors = <ConsentIQError>[];
      final consentIQ = build(
        tcfServer(tcf: tcfJson(gdprApplies: false)),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onError: errors.add,
        ),
      );
      await consentIQ.init();
      expect(errors.map((e) => e.code), ['key-store', 'key-store']);
      expect(consentIQ.isSheetVisible, isTrue);
    });

    test('showSheet re-opens the TCF page; closed keeps the keys', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
        'consentiq_consent': jsonEncode({'necessary': true}),
      });
      var closed = 0;
      final consentIQ = build(
        tcfServer(),
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onClose: () => closed++,
        ),
      );
      await consentIQ.init();
      await pumpEventQueue();
      final first = platform.controllers.single;
      first.post({'type': 'ready'});
      await pumpEventQueue();
      first.answer({'type': 'current'});
      await pumpEventQueue();
      final written = Map.of(keys.store);

      consentIQ.showSheet();
      await pumpEventQueue();
      expect(consentIQ.isSheetVisible, isFalse);
      final second = platform.controllers.last;
      expect(second, isNot(same(first)));
      second.post({'type': 'ready'});
      await pumpEventQueue();
      expect(startOptions(second.scripts.single)['reopen'], isTrue);

      second.answer({'type': 'show'});
      await pumpEventQueue();
      second.answer({'type': 'closed'});
      await pumpEventQueue();
      expect(closed, 1);
      expect(consentIQ.isTcfVisible, isFalse);
      expect(keys.store, written);
      expect(consentIQ.isTcfActive, isTrue);
    });

    test('showTcfPreferences does nothing outside TCF mode', () async {
      final consentIQ = build(FakeServer());
      await consentIQ.init();
      consentIQ.hideSheet();
      consentIQ.showTcfPreferences();
      await pumpEventQueue();
      expect(platform.controllers, isEmpty);
    });

    test('resetConsent forgets the stored TCF record', () async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
      });
      final consentIQ = build(FakeServer());
      await consentIQ.resetConsent();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('consentiq_tcf'), isNull);
    });
  });

  group('ConsentSheet presenting the TCF page', () {
    Future<ConsentIQ> pumpTcfApp(
      WidgetTester tester, {
      ConsentIQConfig options = const ConsentIQConfig(
        propertyKey: testPropertyKey,
      ),
    }) async {
      final consentIQ = build(tcfServer(), options: options);
      await tester.pumpWidget(ConsentIQProvider(
        consentIQ: consentIQ,
        child: const MaterialApp(
          home: ConsentSheet(child: Text('home')),
        ),
      ));
      await consentIQ.init();
      await tester.pump();
      return consentIQ;
    }

    Finder hidden() => find.ancestor(
          of: find.byKey(fakeWebViewKey),
          matching:
              find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.01),
        );

    testWidgets('only after show, full screen; back ignored on a first prompt',
        (tester) async {
      final consentIQ = await pumpTcfApp(tester);
      final web = platform.controllers.single;
      expect(find.byKey(fakeWebViewKey), findsOneWidget);
      expect(hidden(), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);

      web.post({'type': 'ready'});
      await tester.pump();
      expect(hidden(), findsOneWidget);

      web.answer({'type': 'show'});
      await tester.pumpAndSettle();
      expect(find.byKey(fakeWebViewKey), findsOneWidget);
      expect(hidden(), findsNothing);
      expect(
        tester.getSize(find.byKey(fakeWebViewKey)),
        tester.view.physicalSize / tester.view.devicePixelRatio,
      );
      expect(find.text('home'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(fakeWebViewKey), findsOneWidget);
      expect(consentIQ.isTcfVisible, isTrue);

      web.answer(decisionMessage());
      await tester.pumpAndSettle();
      expect(find.byKey(fakeWebViewKey), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(consentIQ.isTcfVisible, isFalse);
      expect(consentIQ.hasConsent('analytics'), isTrue);
    });

    testWidgets('back closes a re-opened page and fires onClose',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
        'consentiq_consent': jsonEncode({'necessary': true}),
      });
      var closed = 0;
      final consentIQ = await pumpTcfApp(
        tester,
        options: ConsentIQConfig(
          propertyKey: testPropertyKey,
          onClose: () => closed++,
        ),
      );
      platform.controllers.single.post({'type': 'ready'});
      await tester.pump();
      platform.controllers.single.answer({'type': 'current'});
      await tester.pumpAndSettle();
      expect(find.byKey(fakeWebViewKey), findsNothing);

      consentIQ.showSheet();
      await tester.pump();
      final web = platform.controllers.last;
      web.post({'type': 'ready'});
      await tester.pump();
      web.answer({'type': 'show'});
      await tester.pumpAndSettle();
      expect(find.text('home'), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
      expect(find.byKey(fakeWebViewKey), findsNothing);
      expect(consentIQ.isTcfVisible, isFalse);
      expect(closed, 1);
    });

    testWidgets('a closed message dismisses the page', (tester) async {
      SharedPreferences.setMockInitialValues({
        'consentiq_tcf': jsonEncode(storedRecord),
      });
      final consentIQ = await pumpTcfApp(tester);
      platform.controllers.single.post({'type': 'ready'});
      await tester.pump();
      platform.controllers.single.answer({'type': 'current'});
      await tester.pump();

      consentIQ.showTcfPreferences();
      await tester.pump();
      final web = platform.controllers.last;
      web.post({'type': 'ready'});
      await tester.pump();
      web.answer({'type': 'show'});
      await tester.pumpAndSettle();
      expect(find.text('home'), findsNothing);

      web.answer({'type': 'closed'});
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    });
  });
}
