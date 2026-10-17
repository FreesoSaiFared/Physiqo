import 'dart:convert';

/// Self-entered numbers only. No photo inference or diagnostic claim.
class BodyFascinationEntry {
  final DateTime recordedAt;
  final double chestCm;
  final double waistCm;
  final double armCm;
  final double wristCm;
  final int pushUps;
  final int plankSeconds;

  const BodyFascinationEntry({
    required this.recordedAt,
    required this.chestCm,
    required this.waistCm,
    required this.armCm,
    required this.wristCm,
    required this.pushUps,
    required this.plankSeconds,
  });

  double get chestToWaist => chestCm / waistCm;
  double get armToWrist => armCm / wristCm;

  /// Guard accidental units, negative values and non-finite input.
  bool get isValid =>
      recordedAt.isBefore(DateTime.now().add(const Duration(days: 1))) &&
      chestCm.isFinite &&
      chestCm >= 40 &&
      chestCm <= 250 &&
      waistCm.isFinite &&
      waistCm >= 35 &&
      waistCm <= 250 &&
      armCm.isFinite &&
      armCm >= 10 &&
      armCm <= 80 &&
      wristCm.isFinite &&
      wristCm >= 8 &&
      wristCm <= 35 &&
      pushUps >= 0 &&
      pushUps <= 200 &&
      plankSeconds >= 0 &&
      plankSeconds <= 900;

  Map<String, Object> toJson() => {
    'recordedAt': recordedAt.toIso8601String(),
    'chestCm': chestCm,
    'waistCm': waistCm,
    'armCm': armCm,
    'wristCm': wristCm,
    'pushUps': pushUps,
    'plankSeconds': plankSeconds,
  };

  static BodyFascinationEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    try {
      final item = BodyFascinationEntry(
        recordedAt: DateTime.parse(value['recordedAt'] as String),
        chestCm: (value['chestCm'] as num).toDouble(),
        waistCm: (value['waistCm'] as num).toDouble(),
        armCm: (value['armCm'] as num).toDouble(),
        wristCm: (value['wristCm'] as num).toDouble(),
        pushUps: (value['pushUps'] as num).toInt(),
        plankSeconds: (value['plankSeconds'] as num).toInt(),
      );
      return item.isValid ? item : null;
    } catch (_) {
      return null;
    }
  }

  static List<BodyFascinationEntry> decodeHistory(String? source) {
    if (source == null || source.isEmpty) return [];
    try {
      final decoded = jsonDecode(source);
      if (decoded is! List) return [];
      final entries = decoded
          .map(BodyFascinationEntry.fromJson)
          .whereType<BodyFascinationEntry>()
          .toList();
      entries.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
      return entries.length <= 24
          ? entries
          : entries.sublist(entries.length - 24);
    } catch (_) {
      return [];
    }
  }

  static String encodeHistory(List<BodyFascinationEntry> entries) =>
      jsonEncode(entries.map((entry) => entry.toJson()).toList());
}

/// Tape units are converted at the input boundary; records remain in cm.
class BodyFascinationUnits {
  static const double cmPerInch = 2.54;
  static double toCm(double input, {required bool inches}) =>
      inches ? input * cmPerInch : input;
  static double fromCm(double cm, {required bool inches}) =>
      inches ? cm / cmPerInch : cm;
}

/// Differences are relative to the preceding test, not population standards.
class BodyFascinationTrend {
  final BodyFascinationEntry current;
  final BodyFascinationEntry? previous;

  const BodyFascinationTrend(this.current, this.previous);

  double? get chestCm =>
      previous == null ? null : current.chestCm - previous!.chestCm;
  double? get waistCm =>
      previous == null ? null : current.waistCm - previous!.waistCm;
  double? get armCm =>
      previous == null ? null : current.armCm - previous!.armCm;
  int? get pushUps =>
      previous == null ? null : current.pushUps - previous!.pushUps;
  int? get plankSeconds =>
      previous == null ? null : current.plankSeconds - previous!.plankSeconds;
}