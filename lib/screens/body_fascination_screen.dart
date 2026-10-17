import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/body_fascination_metrics.dart';
import '../theme/app_theme.dart';
import '../utils/account_manager.dart';
import '../utils/farsi_formatter.dart';
import 'body_scan/scan_capture_flow.dart';

class BodyFascinationScreen extends StatefulWidget {
  const BodyFascinationScreen({super.key});
  @override
  State<BodyFascinationScreen> createState() => _BodyFascinationScreenState();
}

class _BodyFascinationScreenState extends State<BodyFascinationScreen> {
  final _form = GlobalKey<FormState>();
  final _chest = TextEditingController();
  final _waist = TextEditingController();
  final _arm = TextEditingController();
  final _wrist = TextEditingController();
  final _pushups = TextEditingController();
  final _plank = TextEditingController();
  List<BodyFascinationEntry> _history = [];
  bool _loading = true;
  bool _saving = false;
  bool _inches = false;
  int _ego = 0;

  String get _key => AccountManager.getPrefKey('body_fascination_history_v1');

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    for (final c in [_chest, _waist, _arm, _wrist, _pushups, _plank]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = BodyFascinationEntry.decodeHistory(prefs.getString(_key));
    if (!mounted) return;
    setState(() {
      _history = loaded;
      _loading = false;
    });
    if (loaded.isNotEmpty) {
      final last = loaded.last;
      _chest.text = _format(last.chestCm);
      _waist.text = _format(last.waistCm);
      _arm.text = _format(last.armCm);
      _wrist.text = _format(last.wristCm);
      _pushups.text = last.pushUps.toString();
      _plank.text = last.plankSeconds.toString();
    }
  }

  String _format(double cm) =>
      BodyFascinationUnits.fromCm(cm, inches: _inches).toStringAsFixed(1);

  double? _number(String? input) {
    final cleaned = FarsiFormatter.normalizeToEnglish(
      input ?? '',
    ).trim().replaceAll(',', '.');
    final value = double.tryParse(cleaned);
    return value != null && value.isFinite ? value : null;
  }

  int? _integer(String? input) {
    final n = _number(input);
    return n != null && n == n.roundToDouble() ? n.toInt() : null;
  }

  String? _tapeValidator(String? input, double min, double max) {
    final value = _number(input);
    if (value == null) return 'Enter a number';
    final cm = BodyFascinationUnits.toCm(value, inches: _inches);
    return cm >= min && cm <= max ? null : 'Check number / units';
  }

  String? _countValidator(String? input, int max) {
    final count = _integer(input);
    return count != null && count >= 0 && count <= max
        ? null
        : 'Enter 0 to $max';
  }

  void _switchUnit(bool inches) {
    if (inches == _inches) return;
    for (final field in [_chest, _waist, _arm, _wrist]) {
      final n = _number(field.text);
      if (n == null) continue;
      final cm = BodyFascinationUnits.toCm(n, inches: _inches);
      field.text = BodyFascinationUnits.fromCm(
        cm,
        inches: inches,
      ).toStringAsFixed(1);
    }
    setState(() => _inches = inches);
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final entry = BodyFascinationEntry(
        recordedAt: DateTime.now(),
        chestCm: BodyFascinationUnits.toCm(
          _number(_chest.text)!,
          inches: _inches,
        ),
        waistCm: BodyFascinationUnits.toCm(
          _number(_waist.text)!,
          inches: _inches,
        ),
        armCm: BodyFascinationUnits.toCm(_number(_arm.text)!, inches: _inches),
        wristCm: BodyFascinationUnits.toCm(
          _number(_wrist.text)!,
          inches: _inches,
        ),
        pushUps: _integer(_pushups.text)!,
        plankSeconds: _integer(_plank.text)!,
      );
      if (!entry.isValid) throw const FormatException('Invalid entry');
      final records = [..._history, entry];
      final next = records.length <= 24
          ? records
          : records.sublist(records.length - 24);
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        _key,
        BodyFascinationEntry.encodeHistory(next),
      ))
        throw StateError('Local write failed');
      if (!mounted) return;
      setState(() => _history = next);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Test logged. The evidence is yours.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save this test locally.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _erase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Erase local test history?'),
        content: const Text(
          'All BodyFasciNation records for this profile will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(_key)) return;
    if (!mounted) return;
    setState(() {
      _history = [];
      _ego = 0;
    });
    for (final field in [_chest, _waist, _arm, _wrist, _pushups, _plank]) {
      field.clear();
    }
  }

  Future<void> _offerCamera() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Optional AI photo scan'),
        content: const Text(
          'The existing Physiqo scanner sends front and back photos to '
          'your configured third-party AI provider. Its visual scores are '
          'estimates, not physical measurements. The manual tester uploads nothing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay local'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open scanner'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => const ScanCaptureFlow()),
      );
    }
  }

  Widget _stat(String title, String figure) => Container(
    padding: const EdgeInsets.all(14),
    decoration: AppTheme.cardDecoration(),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTheme.labelMd.copyWith(
            color: AppTheme.textSecondary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          figure,
          style: AppTheme.headlineLg.copyWith(color: AppTheme.primary),
        ),
        Text(
          'Circumference ratio',
          style: AppTheme.labelMd.copyWith(color: AppTheme.textSecondary),
        ),
      ],
    ),
  );

  Widget _delta(String name, num? n, String suffix) => Row(
    children: [
      Expanded(child: Text(name)),
      Text(
        n == null
            ? '—'
            : (n > 0 ? '+' : '') + n.toStringAsFixed(n is int ? 0 : 1) + suffix,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
    ],
  );

  Widget _readout() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_history.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: AppTheme.cardDecoration(active: true),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'NO EVIDENCE ON FILE',
              style: TextStyle(
                color: AppTheme.primary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            SizedBox(height: 10),
            Text(
              'A tape measure beats an intimidating mirror. Make your first baseline.',
            ),
          ],
        ),
      );
    }
    final latest = _history.last;
    final previous = _history.length > 1 ? _history[_history.length - 2] : null;
    final trend = BodyFascinationTrend(latest, previous);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _stat(
                'CHEST / WAIST',
                latest.chestToWaist.toStringAsFixed(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _stat('ARM / WRIST', latest.armToWrist.toStringAsFixed(2)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                previous == null ? 'BASELINE' : 'CHANGE SINCE PREVIOUS TEST',
                style: AppTheme.labelMd.copyWith(
                  color: AppTheme.primary,
                  letterSpacing: 1.1,
                ),
              ),
              if (previous == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'Log another session to compare against yourself. No population ranking.',
                  ),
                ),
              if (previous != null) ...[
                _delta('Chest', trend.chestCm, ' cm'),
                _delta('Waist', trend.waistCm, ' cm'),
                _delta('Arm', trend.armCm, ' cm'),
                _delta('Push-ups', trend.pushUps, ''),
                _delta('Plank', trend.plankSeconds, ' s'),
              ],
              const SizedBox(height: 10),
              Text(
                _history.length.toString() + ' local records',
                style: AppTheme.labelMd.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _field(
    String label,
    String keyName,
    TextEditingController controller,
    String? Function(String?) validator,
  ) => TextFormField(
    key: Key(keyName),
    controller: controller,
    textDirection: TextDirection.ltr,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: validator,
    decoration: InputDecoration(
      labelText: label,
      filled: true,
      fillColor: AppTheme.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        borderSide: const BorderSide(color: AppTheme.primary),
      ),
    ),
  );

  Widget _fields() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth >= 350
          ? (constraints.maxWidth - 12) / 2
          : constraints.maxWidth;
      final unit = _inches ? 'in' : 'cm';
      final inputs = [
        _field(
          'Chest ($unit)',
          'bf-chest',
          _chest,
          (v) => _tapeValidator(v, 40, 250),
        ),
        _field(
          'Waist ($unit)',
          'bf-waist',
          _waist,
          (v) => _tapeValidator(v, 35, 250),
        ),
        _field(
          'Flexed arm ($unit)',
          'bf-arm',
          _arm,
          (v) => _tapeValidator(v, 10, 80),
        ),
        _field(
          'Wrist ($unit)',
          'bf-wrist',
          _wrist,
          (v) => _tapeValidator(v, 8, 35),
        ),
        _field(
          'Push-ups / set',
          'bf-pushups',
          _pushups,
          (v) => _countValidator(v, 200),
        ),
        _field(
          'Plank seconds',
          'bf-plank',
          _plank,
          (v) => _countValidator(v, 900),
        ),
      ];
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final input in inputs) SizedBox(width: width, child: input),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    return Directionality(
      textDirection: {'fa', 'ar', 'ur'}.contains(lang)
          ? TextDirection.rtl
          : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          title: const Text('B/F  •  TEST CHAMBER'),
          actions: [
            if (_history.isNotEmpty)
              IconButton(
                tooltip: 'Erase local history',
                icon: const Icon(Icons.delete_outline),
                onPressed: _erase,
              ),
          ],
        ),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'FIELD LAB / 001    •    SELF-COMPARISON',
                  style: AppTheme.labelMd.copyWith(
                    color: AppTheme.textSecondary,
                    letterSpacing: 1.3,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'BODY',
                  style: AppTheme.headlineLg.copyWith(
                    fontSize: 48,
                    height: 0.95,
                    letterSpacing: -1.5,
                  ),
                ),
                Text(
                  'FASCI NATION',
                  style: AppTheme.headlineLg.copyWith(
                    fontSize: 36,
                    color: AppTheme.primary,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'FOR THE COMPENSATING MAN',
                  style: AppTheme.bodyMd.copyWith(
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tiny ego. Magnificent data. Every body starts somewhere.',
                  style: AppTheme.bodyMd.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 20),
                _readout(),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: AppTheme.cardDecoration(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'THE COMPENSATION AMPLIFIER',
                        style: AppTheme.labelMd.copyWith(
                          color: AppTheme.primary,
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Theatrical confidence: $_ego dB',
                        style: AppTheme.headlineMd.copyWith(fontSize: 20),
                      ),
                      Text(
                        'Completely fictional. Never included in your actual results.',
                        style: AppTheme.labelMd.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('bf-amplify'),
                        onPressed: () =>
                            setState(() => _ego = (_ego + 10) % 110),
                        icon: const Icon(Icons.volume_up_outlined),
                        label: const Text('INFLATE THE EGO'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'THE ACTUAL TEST',
                        style: AppTheme.headlineMd.copyWith(fontSize: 19),
                      ),
                    ),
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('cm')),
                        ButtonSegment(value: true, label: Text('in')),
                      ],
                      selected: {_inches},
                      onSelectionChanged: (value) => _switchUnit(value.first),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _fields(),
                const SizedBox(height: 16),
                Text(
                  'Measure the same locations and use consistent push-up and plank '
                  'technique. Ratios are arithmetic, not medical or beauty scores.',
                  style: AppTheme.labelMd.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  key: const Key('bf-ai-scan'),
                  onPressed: _offerCamera,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('OPTIONAL AI CAMERA SCAN'),
                ),
                const SizedBox(height: 10),
                Text(
                  'Manual tests require no API key or photo upload. '
                  'History is in on-device app preferences, not encrypted.',
                  style: AppTheme.labelMd.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              height: 52,
              child: ElevatedButton(
                key: const Key('bf-save'),
                onPressed: _saving || _loading ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: AppTheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                child: Text(
                  _saving ? 'SAVING...' : 'LOG THIS TEST',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}