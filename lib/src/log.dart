import 'package:flutter/foundation.dart';

const String logPrefix = '[ConsentIQ]';

class ConsentIQLogger {
  const ConsentIQLogger({this.debug = false});

  final bool debug;

  void log(String message) {
    if (debug) debugPrint('$logPrefix $message');
  }

  void warn(String message) => debugPrint('$logPrefix $message');
}
