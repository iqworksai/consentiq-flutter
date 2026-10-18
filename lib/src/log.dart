import 'package:flutter/foundation.dart';

import 'api_client.dart';

const String logPrefix = '[ConsentIQ]';

class ConsentIQLogger {
  const ConsentIQLogger({this.debug = false});

  final bool debug;

  void log(String message) {
    if (debug) debugPrint('$logPrefix $message');
  }

  // Prints in release builds too, so it never carries raw error text: an http
  // error's string includes the request URL, which ends in the subject id.
  void warn(String message, [Object? error]) {
    debugPrint(error == null
        ? '$logPrefix $message'
        : '$logPrefix $message: ${describeError(error)}');
    if (error != null && debug && kDebugMode) debugPrint('$logPrefix $error');
  }
}

String describeError(Object error) => switch (error) {
      ConsentIQApiException(:final statusCode?) => 'HTTP $statusCode',
      _ => error.runtimeType.toString(),
    };
