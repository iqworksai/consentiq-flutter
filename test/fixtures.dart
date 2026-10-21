import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String testPropertyKey = 'pk_test_123';
const String testApiUrl = 'https://consent.example.test';

Map<String, dynamic> configJson({
  bool requireCaptcha = false,
  String? turnstileSiteKey,
  String? defaultLanguage = 'en',
  String? noticeUrl = 'https://consent.example.test/api/public/privacy/pk',
  String? primaryColor = '#123456',
  String? bannerBgColor,
  String? bannerTextColor,
  String? bannerDescription = 'We use cookies to improve your experience.',
  Map<String, dynamic>? tcf,
}) =>
    {
      'property': {
        'id': 'prop-1',
        'name': 'Demo App',
        'identifier': 'ai.iqworks.demo',
        'platform': 'ios',
        'defaultLanguage': defaultLanguage,
        'supportedLanguages': ['en', 'ar'],
      },
      'banner': {
        'position': 'bottom',
        'layout': 'banner',
        'theme': 'dark',
        'showLogo': false,
        'primaryColor': primaryColor,
        if (bannerBgColor != null) 'bannerBgColor': bannerBgColor,
        if (bannerTextColor != null) 'bannerTextColor': bannerTextColor,
        'cornerStyle': 'rounded',
        'showCookieIcon': false,
        'overlay': false,
        'noticeUrl': noticeUrl,
      },
      'categories': [
        {
          'code': 'necessary',
          'enabled': true,
          'defaultState': true,
          'name': 'Necessary',
          'description': 'Required for the app to work',
          'isRequired': true,
        },
        {
          'code': 'analytics',
          'enabled': true,
          'defaultState': false,
          'name': 'Analytics',
          'isRequired': false,
        },
        {
          'code': 'marketing',
          'enabled': true,
          'defaultState': false,
          'name': 'Marketing',
          'isRequired': false,
        },
      ],
      'marketingChannels': [
        {
          'code': 'email',
          'name': 'Email',
          'description': 'Email updates',
          'requiresDoubleOptin': false,
        },
      ],
      'geoRules': [
        {
          'countries': ['IN'],
          'regulation': 'DPDPA',
          'requireExplicitConsent': true,
        },
      ],
      'resolvedRegulation': 'DPDPA',
      'privacyNotices': <Object>[],
      'formConsentSources': <Object>[],
      'privacyNoticeUrl': null,
      'requireCaptcha': requireCaptcha,
      'turnstileSiteKey': turnstileSiteKey,
      'autoBlock': false,
      'translations': {
        'en': {
          'bannerDescription': bannerDescription,
          'categories': {
            'analytics': {
              'title': 'Analytics cookies',
              'description': 'Help us understand usage.',
            },
          },
        },
        'ar': {
          'bannerDescription': 'نستخدم ملفات تعريف الارتباط.',
          'categories': {
            'analytics': {'title': 'تحليلات', 'description': 'وصف'},
          },
        },
      },
      'labels': {
        'en': {
          'title': 'We value your privacy',
          'acceptAll': 'Accept all',
          'acceptRequired': 'Accept only required',
          'reject': 'Reject all',
          'customize': 'Customize',
          'save': 'Save preferences',
          'preferencesTitle': 'Cookie preferences',
          'viewNotice': 'View cookie notice',
        },
        'ar': {
          'title': 'نحن نحترم خصوصيتك',
          'acceptAll': 'قبول الكل',
          'acceptRequired': 'قبول الضروري فقط',
          'reject': 'رفض الكل',
          'customize': 'تخصيص',
          'save': 'حفظ التفضيلات',
          'preferencesTitle': 'تفضيلات',
          'viewNotice': 'عرض الإشعار',
        },
      },
      'rtl': ['ar', 'ur', 'ks', 'sd'],
      if (tcf != null) 'tcf': tcf,
      'someFutureField': {'ignored': true},
    };

Map<String, dynamic> tcfJson({
  bool enabled = true,
  bool gdprApplies = true,
  int cmpId = 300,
  int cmpVersion = 1,
}) =>
    {
      'enabled': enabled,
      'gdprApplies': gdprApplies,
      'vendorIds': [1, 2, 755],
      'publisherCountryCode': 'DE',
      'publisherRestrictions': [
        {
          'purposeId': 2,
          'restrictionType': 1,
          'vendorIds': [755],
        },
      ],
      'repromptMonths': 13,
      'tcfPolicyVersion': 5,
      'cmpId': cmpId,
      'cmpVersion': cmpVersion,
      'vendorListUrl': '/api/public/tcf/$testPropertyKey/vendor-list?v=abc',
    };

Map<String, dynamic> savedConsentJson({
  Map<String, bool> cookieConsents = const {
    'necessary': true,
    'analytics': true,
    'marketing': false,
  },
  Map<String, bool>? marketingConsents = const {'email': true},
}) =>
    {
      'consent': {
        'id': 'consent-1',
        'cookieConsents': cookieConsents,
        'marketingConsents': marketingConsents,
        'consentedAt': '2026-01-01T00:00:00.000Z',
        'expiresAt': null,
        'regulationApplied': null,
        'consentVersion': null,
      },
    };

const Map<String, String> jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

http.Response jsonResponse(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: jsonHeaders);

class RecordedRequest {
  RecordedRequest(this.request, this.body);

  final http.Request request;
  final String body;

  String get method => request.method;
  String get url => request.url.toString();
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

/// A MockClient that routes by path and records every request.
class FakeServer {
  FakeServer({
    Map<String, dynamic>? config,
    Map<String, dynamic>? consent,
    int configStatus = 200,
    int consentStatus = 200,
    int submitStatus = 200,
    Map<String, dynamic>? submitBody,
  })  : _config = config ?? configJson(),
        _consent = consent ?? const {'consent': null},
        _configStatus = configStatus,
        _consentStatus = consentStatus,
        _submitStatus = submitStatus,
        _submitBody = submitBody ??
            const {'success': true, 'consentId': 'c-1', 'proofHash': 'hash'};

  final Map<String, dynamic> _config;
  final Map<String, dynamic> _consent;
  final int _configStatus;
  final int _consentStatus;
  final int _submitStatus;
  final Map<String, dynamic> _submitBody;
  final List<RecordedRequest> requests = [];

  List<RecordedRequest> get submits =>
      requests.where((r) => r.method == 'POST').toList();

  http.Client get client => MockClient((request) async {
        requests.add(RecordedRequest(request, request.body));
        final path = request.url.path;
        if (path.startsWith('/api/public/config/')) {
          return jsonResponse(_config, _configStatus);
        }
        if (path == '/api/public/consent' && request.method == 'POST') {
          return jsonResponse(_submitBody, _submitStatus);
        }
        if (path.startsWith('/api/public/consent/')) {
          return jsonResponse(_consent, _consentStatus);
        }
        return http.Response('{"error":"Not found"}', 404);
      });
}

/// A captcha token source that counts its calls and returns [token], or
/// throws when [token] is null.
class FakeCaptcha {
  FakeCaptcha([this.token = 'tok']);

  final String? token;
  int calls = 0;

  Future<String> call() async {
    calls++;
    final value = token;
    if (value == null) throw StateError('no token');
    return value;
  }
}

/// Captures `debugPrint` output for the duration of a test body.
Future<List<String>> captureLogs(Future<void> Function() body) async {
  final logs = <String>[];
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) logs.add(message);
  };
  try {
    await body();
  } finally {
    debugPrint = previous;
  }
  return logs;
}
