import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physiqo/models/body_fascination_metrics.dart';
import 'package:physiqo/screens/body_fascination_screen.dart';
import 'package:physiqo/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

BodyFascinationEntry entry({
  double chest = 100,
  double waist = 80,
  double arm = 30,
  double wrist = 15,
  int pushups = 12,
  int plank = 45,
  DateTime? date,
}) => BodyFascinationEntry(
  recordedAt: date ?? DateTime.utc(2026, 10, 10),
  chestCm: chest,
  waistCm: waist,
  armCm: arm,
  wristCm: wrist,
  pushUps: pushups,
  plankSeconds: plank,
);

void main() {
  test('unit conversion round-trips', () {
    final inches = BodyFascinationUnits.fromCm(98.5, inches: true);
    expect(
      BodyFascinationUnits.toCm(inches, inches: true),
      closeTo(98.5, 0.000001),
    );
    expect(BodyFascinationUnits.toCm(99, inches: false), 99);
  });

  test('ratios are arithmetic; invalid entries rejected', () {
    expect(entry().chestToWaist, 1.25);
    expect(entry().armToWrist, 2);
    expect(entry(waist: 0).isValid, isFalse);
    expect(entry(chest: double.nan).isValid, isFalse);
    expect(entry(pushups: -1).isValid, isFalse);
    expect(BodyFascinationEntry.decodeHistory('broken'), isEmpty);
    expect(BodyFascinationEntry.decodeHistory('[1, null, {}]'), isEmpty);
  });

  test('history is sorted, capped at 24, and decodes cleanly', () {
    final series = List.generate(
      28,
      (i) => entry(
        chest: 90 + i.toDouble(),
        date: DateTime.utc(2026, 8, 1).add(Duration(days: i)),
      ),
    );
    final decoded = BodyFascinationEntry.decodeHistory(
      BodyFascinationEntry.encodeHistory(series.reversed.toList()),
    );
    expect(decoded, hasLength(24));
    expect(decoded.first.chestCm, 94);
    expect(decoded.last.chestCm, 117);
  });

  test('trend compares with previous record, not peers', () {
    final t = BodyFascinationTrend(
      entry(chest: 102, waist: 79, pushups: 18, plank: 60),
      entry(chest: 100, waist: 80, pushups: 10, plank: 40),
    );
    expect(t.chestCm, 2);
    expect(t.waistCm, -1);
    expect(t.pushUps, 8);
    expect(t.plankSeconds, 20);
    expect(BodyFascinationTrend(entry(), null).armCm, isNull);
  });

  testWidgets('confidence amplifier is explicitly fictional', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(950, 2300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: const BodyFascinationScreen(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('FOR THE COMPENSATING MAN'), findsOneWidget);
    expect(find.text('NO EVIDENCE ON FILE'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bf-amplify')));
    await tester.pumpAndSettle();
    expect(find.textContaining('10 dB'), findsOneWidget);
  });

  testWidgets('saving a measurement creates a local baseline', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(950, 2300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: const BodyFascinationScreen(),
      ),
    );
    await tester.pumpAndSettle();
    for (final pair in [
      ('bf-chest', '100'),
      ('bf-waist', '80'),
      ('bf-arm', '30'),
      ('bf-wrist', '15'),
      ('bf-pushups', '15'),
      ('bf-plank', '60'),
    ]) {
      await tester.enterText(find.byKey(Key(pair.$1)), pair.$2);
    }
    await tester.tap(find.byKey(const Key('bf-save')));
    await tester.pumpAndSettle();
    expect(find.text('1 local records'), findsOneWidget);
    expect(find.text('1.25'), findsOneWidget);
    expect(find.text('2.00'), findsOneWidget);
  });
}