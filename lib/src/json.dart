Map<String, dynamic> asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
  return const {};
}

String? asStringOrNull(Object? value) => value is String ? value : null;

String asString(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

bool asBool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

int? asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

List<String> asStringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

List<Map<String, dynamic>> asMapList(Object? value) =>
    value is List ? value.map(asMap).toList(growable: false) : const [];

Map<String, bool> asBoolMap(Object? value) {
  final out = <String, bool>{};
  asMap(value).forEach((k, v) {
    if (v is bool) out[k] = v;
  });
  return out;
}
