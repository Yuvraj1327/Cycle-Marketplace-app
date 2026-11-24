/// Tolerant JSON readers: the backend sends money/quantities as JSON numbers (int or double) and omits nothing, but the app must never crash on shape.
double asDouble(dynamic v, [double fallback = 0]) => v is num
    ? v.toDouble()
    : (v is String ? double.tryParse(v) ?? fallback : fallback);
int asInt(dynamic v, [int fallback = 0]) => v is num
    ? v.toInt()
    : (v is String ? int.tryParse(v) ?? fallback : fallback);
double? asDoubleOrNull(dynamic v) => v == null ? null : asDouble(v);
String? asStringOrNull(dynamic v) => v?.toString();
DateTime? asDate(dynamic v) => v is String ? DateTime.tryParse(v) : null;
Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> asMapList(dynamic v) => v is List
    ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList()
    : <Map<String, dynamic>>[];
