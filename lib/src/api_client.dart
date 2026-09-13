import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'consent_state.dart';
import 'json.dart';
import 'log.dart';
import 'models.dart';

class ConsentIQApiException implements Exception {
  const ConsentIQApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ConsentIQApiException: $message';
}

class ConsentIQApiClient {
  ConsentIQApiClient({
    required this.propertyKey,
    String apiUrl = defaultApiUrl,
    http.Client? client,
    bool debug = false,
  })  : apiUrl = _trimSlash(apiUrl),
        _client = client ?? http.Client(),
        _ownsClient = client == null,
        _logger = ConsentIQLogger(debug: debug);

  final String propertyKey;
  final String apiUrl;
  final http.Client _client;
  final bool _ownsClient;
  final ConsentIQLogger _logger;

  static String _trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  static const Map<String, String> _headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Future<PropertyConfig> getConfig() async {
    _logger.log('Fetching config for property $propertyKey');
    final json = await _get(
      '/api/public/config/${Uri.encodeComponent(propertyKey)}',
    );
    _logger.log('Config loaded');
    return PropertyConfig.fromJson(json);
  }

  Future<ConsentLookup> getConsent(String subjectId) async {
    _logger.log('Fetching consent for subject $subjectId');
    final json = await _get(
      '/api/public/consent/${Uri.encodeComponent(propertyKey)}'
      '/${Uri.encodeComponent(subjectId)}',
    );
    final lookup = ConsentLookup.fromJson(json);
    _logger.log(
      lookup.consent == null
          ? (lookup.expired ? 'Consent expired' : 'No consent on record')
          : 'Consent loaded',
    );
    return lookup;
  }

  Future<ConsentSubmission> submitConsent({
    required String subjectId,
    String? subjectType,
    ConsentState? cookieConsents,
    MarketingConsentState? marketingConsents,
    String? geoCountry,
    String? geoRegion,
    String? geoSource,
    String consentMethod = 'sdk',
    String? consentVersion,
  }) async {
    final body = <String, Object?>{
      'propertyKey': propertyKey,
      'subjectId': subjectId,
      if (subjectType != null) 'subjectType': subjectType,
      if (cookieConsents != null) 'cookieConsents': cookieConsents,
      if (marketingConsents != null) 'marketingConsents': marketingConsents,
      if (geoCountry != null) 'geoCountry': geoCountry,
      if (geoRegion != null) 'geoRegion': geoRegion,
      if (geoSource != null) 'geoSource': geoSource,
      'consentMethod': consentMethod,
      if (consentVersion != null) 'consentVersion': consentVersion,
    };
    _logger.log('Submitting consent ($consentMethod)');
    final json = await _post('/api/public/consent', body);
    final result = ConsentSubmission.fromJson(json);
    _logger.log('Consent submitted: ${result.consentId}');
    return result;
  }

  Future<ConsentVerification> verifyConsent(String consentId) async {
    final json = await _get(
      '/api/public/verify/${Uri.encodeComponent(consentId)}',
    );
    return ConsentVerification.fromJson(json);
  }

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await _client.get(
      Uri.parse('$apiUrl$path'),
      headers: _headers,
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final response = await _client.post(
      Uri.parse('$apiUrl$path'),
      headers: _headers,
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final status = response.statusCode;
    Object? parsed;
    try {
      parsed = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      parsed = null;
    }
    if (status < 200 || status >= 300) {
      final message = asStringOrNull(asMap(parsed)['error']);
      throw ConsentIQApiException(
        message == null || message.isEmpty ? 'HTTP $status' : message,
        statusCode: status,
      );
    }
    if (parsed is! Map) {
      throw ConsentIQApiException(
        'Unexpected response body',
        statusCode: status,
      );
    }
    return asMap(parsed);
  }
}
