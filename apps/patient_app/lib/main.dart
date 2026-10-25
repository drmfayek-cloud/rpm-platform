import 'dart:async';

import 'package:flutter/material.dart';

import 'device/bp_device.dart';
import 'device/device_factory.dart';
import 'device/fake_bp_device.dart';
import 'device/permissions.dart';

// Week-1 build: a device test bench to prove the HC03 works end to end with our app
// on real phones, before the patient screens are built on top of it.
void main() => runApp(const DeviceTestApp());

class DeviceTestApp extends StatelessWidget {
  const DeviceTestApp({super.key, this.device});
  final BpDevice? device;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RPM device test',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F766E), useMaterial3: true),
      home: DeviceTestScreen(device: device ?? createBpDevice()),
    );
  }
}

class DeviceTestScreen extends StatefulWidget {
  const DeviceTestScreen({super.key, required this.device});
  final BpDevice device;

  @override
  State<DeviceTestScreen> createState() => _DeviceTestScreenState();
}

class _DeviceTestScreenState extends State<DeviceTestScreen> {
  BpDevice get device => widget.device;
  StreamSubscription<DeviceEvent>? _sub;

  bool _ready = false;
  DeviceConnection _connection = DeviceConnection.unbound;
  List<ScannedDevice> _scanned = const [];
  bool _scanning = false;
  String? _sn;
  int? _battery;
  bool _charging = false;
  bool _measuring = false;
  DateTime? _measureStarted;
  BpResult? _last;
  String? _lastError;
  final List<BpResult> _session = [];
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _sub = device.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    device.dispose();
    super.dispose();
  }

  void _addLog(String s) {
    final t = TimeOfDay.now().format(context);
    setState(() {
      _log.insert(0, '$t  $s');
      if (_log.length > 200) _log.removeLast();
    });
  }

  void _onEvent(DeviceEvent e) {
    switch (e) {
      case DeviceReady():
        setState(() => _ready = true);
        _addLog('SDK service started');
      case StatusChanged(:final status):
        setState(() {
          _connection = status.connection;
          _sn = status.deviceSn ?? _sn;
          _battery = status.battery ?? _battery;
        });
      case ConnectionChanged(:final connection):
        setState(() {
          _connection = connection;
          if (connection == DeviceConnection.disconnected) {
            _sn = null;
            _measuring = false;
          }
        });
        _addLog('Connection: ${connection.name}');
      case ScanResults(:final devices):
        setState(() => _scanned = devices);
      case DeviceIdentified(:final deviceSn):
        setState(() => _sn = deviceSn);
        _addLog(deviceSn == null ? 'Could not read device ID' : 'Device ID: $deviceSn');
      case BatteryChanged(:final level, :final charging):
        setState(() {
          _battery = level;
          _charging = charging;
        });
      case BpStarted():
        setState(() {
          _measuring = true;
          _measureStarted = DateTime.now();
          _lastError = null;
        });
        _addLog('Measurement started');
      case BpMeasured(:final result):
        final secs = _measureStarted == null ? null : DateTime.now().difference(_measureStarted!).inSeconds;
        setState(() {
          _measuring = false;
          _last = result;
          _session.insert(0, result);
        });
        _addLog('Result $result${secs == null ? '' : ' in ${secs}s'}${result.isPlausible ? '' : '  (IMPLAUSIBLE)'}');
      case BpFailed(:final reason):
        setState(() {
          _measuring = false;
          _lastError = _failureText(reason);
        });
        _addLog('Measurement failed: ${reason.name}');
      case DeviceErrorEvent(:final message):
        _addLog('ERROR: $message');
      case DeviceLog(:final message):
        _addLog(message);
    }
  }

  String _failureText(BpFailureReason r) => switch (r) {
        BpFailureReason.leak => 'Air leak — check the cuff and tube are firmly connected, then retry.',
        BpFailureReason.movement => 'Movement or talking disturbed the reading. Sit still and quiet, then retry.',
        BpFailureReason.calculation => 'The device could not calculate a result. Retry in 1–2 minutes.',
        BpFailureReason.lowBattery => 'Device battery is low. Charge the HC03 and retry.',
        BpFailureReason.notConnected => 'The device is not connected.',
        BpFailureReason.busy => 'A measurement is already running.',
        BpFailureReason.other => 'Measurement failed. Retry.',
      };

  Future<void> _guard(String label, Future<void> Function() action) async {
    try {
      await action();
    } on DeviceException catch (e) {
      _addLog('$label failed: ${e.message}');
      if (e.reason != null) setState(() => _lastError = _failureText(e.reason!));
    } catch (e) {
      _addLog('$label failed: $e');
    }
  }

  Future<void> _start() => _guard('Start', () async {
        final ok = await requestBluetoothPermissions();
        if (!ok) {
          _addLog('Bluetooth permission denied — allow "Nearby devices" (or Location) in Settings');
          return;
        }
        await device.initialize();
        final s = await device.status();
        setState(() {
          _ready = true;
          _connection = s.connection;
        });
      });

  Future<void> _scan() => _guard('Scan', () async {
        if (_scanning) {
          await device.stopScan();
          setState(() => _scanning = false);
        } else {
          setState(() {
            _scanned = const [];
            _scanning = true;
          });
          await device.startScan();
        }
      });

  Future<void> _connect(ScannedDevice d) => _guard('Connect', () async {
        await device.stopScan();
        setState(() => _scanning = false);
        _addLog('Connecting to $d');
        await device.connect(d.mac);
      });

  bool get _canMeasure =>
      !_measuring && (_connection == DeviceConnection.ready || _connection == DeviceConnection.connected);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('HC03 device test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(device.implementationName, style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),
          if (!device.supportsMeasurement)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('Device readings are not supported on this phone yet. Use the Android hub phone.'),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _row('Status', _ready ? _connection.name : 'not started'),
                _row('Device ID', _sn ?? '—'),
                _row('Battery', _battery == null ? '—' : '$_battery%${_charging ? ' (charging)' : ''}'),
              ]),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!_ready) FilledButton(onPressed: _start, child: const Text('Start')),
            if (_ready && _connection == DeviceConnection.bluetoothOff)
              FilledButton(onPressed: () => _guard('Bluetooth', device.openBluetooth), child: const Text('Turn on Bluetooth')),
            if (_ready && _connection == DeviceConnection.disconnected)
              OutlinedButton(onPressed: _scan, child: Text(_scanning ? 'Stop scan' : 'Find devices')),
            if (_ready && _sn != null)
              OutlinedButton(onPressed: () => _guard('Disconnect', device.disconnect), child: const Text('Disconnect')),
          ]),
          if (_scanned.isNotEmpty && _connection == DeviceConnection.disconnected) ...[
            const SizedBox(height: 8),
            Text('Nearby devices', style: theme.textTheme.titleSmall),
            for (final d in _scanned)
              ListTile(
                title: Text(d.name ?? 'Unknown device'),
                subtitle: Text('${d.mac}   signal ${d.rssi ?? '-'}'),
                trailing: const Icon(Icons.bluetooth),
                onTap: () => _connect(d),
              ),
          ],
          const SizedBox(height: 16),
          if (device is FakeBpDevice) _scenarioPicker(device as FakeBpDevice),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _canMeasure ? () => _guard('Measure', device.startBloodPressure) : null,
              icon: _measuring
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.favorite),
              label: Text(_measuring ? 'Measuring… keep still' : 'Measure blood pressure'),
            ),
          ),
          if (_measuring)
            TextButton(onPressed: () => _guard('Stop', device.stopBloodPressure), child: const Text('Cancel')),
          if (_lastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_lastError!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (_last != null)
            Card(
              margin: const EdgeInsets.only(top: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text('${_last!.systolic}/${_last!.diastolic}', style: theme.textTheme.displayMedium),
                  Text('mmHg   ·   pulse ${_last!.pulse ?? '-'}/min'),
                ]),
              ),
            ),
          if (_session.length > 1) ...[
            const SizedBox(height: 12),
            Text('This session', style: theme.textTheme.titleSmall),
            for (final r in _session) Text('${TimeOfDay.fromDateTime(r.measuredAt).format(context)}   $r'),
          ],
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Technical log'),
            children: [for (final l in _log) Align(alignment: Alignment.centerLeft, child: Text(l))],
          ),
        ],
      ),
    );
  }

  Widget _scenarioPicker(FakeBpDevice fake) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<FakeScenario>(
          value: fake.nextScenario,
          decoration: const InputDecoration(labelText: 'Simulator: next result'),
          items: [for (final s in FakeScenario.values) DropdownMenuItem(value: s, child: Text(s.name))],
          onChanged: (s) => setState(() => fake.nextScenario = s ?? FakeScenario.normal),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [SizedBox(width: 90, child: Text(k)), Expanded(child: Text(v))]),
      );
}
