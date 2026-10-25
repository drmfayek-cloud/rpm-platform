import 'dart:async';
import 'dart:math';

import 'bp_device.dart';

/// Scenario the simulator should produce on the next measurement.
enum FakeScenario { normal, high, urgentHigh, low, leak, movement }

/// Simulated blood pressure monitor for development, demos and automated tests.
/// Behaves like the HC03 flow: scan → connect → identified → ready → measure (~25 s, shortened here).
class FakeBpDevice implements BpDevice {
  FakeBpDevice({this.measureDuration = const Duration(seconds: 4), Random? random})
      : _random = random ?? Random();

  final Duration measureDuration;
  final Random _random;
  final _controller = StreamController<DeviceEvent>.broadcast();

  FakeScenario nextScenario = FakeScenario.normal;
  DeviceConnection _connection = DeviceConnection.unbound;
  bool _measuring = false;
  String? _sn;
  Timer? _timer;

  static const fakeDevices = [
    ScannedDevice(mac: 'AA:BB:CC:00:00:01', name: 'HC03-SIM-01', rssi: -55),
    ScannedDevice(mac: 'AA:BB:CC:00:00:02', name: 'HC03-SIM-02', rssi: -71),
  ];

  @override
  String get implementationName => 'Simulator';

  @override
  bool get supportsMeasurement => true;

  @override
  Stream<DeviceEvent> get events => _controller.stream;

  void _emit(DeviceEvent e) => scheduleMicrotask(() => _controller.add(e));

  @override
  Future<void> initialize() async {
    _connection = DeviceConnection.disconnected;
    _emit(const DeviceReady());
    _emit(const ConnectionChanged(DeviceConnection.disconnected));
  }

  @override
  Future<DeviceStatus> status() async => DeviceStatus(
        connection: _connection,
        deviceSn: _sn,
        battery: 80,
        measuring: _measuring,
        firmwareVersion: 'sim-1.0',
        sdkVersion: 'simulator',
      );

  @override
  Future<void> openBluetooth() async {}

  @override
  Future<void> startScan() async => _emit(const ScanResults(fakeDevices));

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String mac) async {
    _connection = DeviceConnection.connecting;
    _emit(const ConnectionChanged(DeviceConnection.connecting));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _sn = 'sim${mac.replaceAll(':', '').toLowerCase()}';
    _connection = DeviceConnection.ready;
    _emit(const ConnectionChanged(DeviceConnection.ready));
    _emit(DeviceIdentified(_sn));
    _emit(const BatteryChanged(level: 80, charging: false, full: false));
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _measuring = false;
    _sn = null;
    _connection = DeviceConnection.disconnected;
    _emit(const ConnectionChanged(DeviceConnection.disconnected));
  }

  @override
  Future<void> startBloodPressure() async {
    if (_connection != DeviceConnection.ready) {
      throw DeviceException('NOT_CONNECTED', 'Device is not connected', reason: BpFailureReason.notConnected);
    }
    if (_measuring) throw DeviceException('BUSY', 'A measurement is already running', reason: BpFailureReason.busy);
    _measuring = true;
    _emit(const BpStarted());
    final scenario = nextScenario;
    _timer = Timer(measureDuration, () {
      _measuring = false;
      switch (scenario) {
        case FakeScenario.leak:
          _emit(const BpFailed(BpFailureReason.leak));
        case FakeScenario.movement:
          _emit(const BpFailed(BpFailureReason.movement));
        default:
          _emit(BpMeasured(_reading(scenario)));
      }
    });
  }

  BpResult _reading(FakeScenario s) {
    int jitter(int range) => _random.nextInt(range * 2 + 1) - range;
    final (sys, dia) = switch (s) {
      FakeScenario.high => (148 + jitter(6), 94 + jitter(4)),
      FakeScenario.urgentHigh => (186 + jitter(4), 112 + jitter(3)),
      FakeScenario.low => (86 + jitter(3), 56 + jitter(3)),
      _ => (124 + jitter(6), 79 + jitter(4)),
    };
    return BpResult(
      systolic: sys,
      diastolic: dia,
      pulse: 72 + jitter(8),
      measuredAt: DateTime.now(),
      deviceSn: _sn,
      firmwareVersion: 'sim-1.0',
      sdkVersion: 'simulator',
    );
  }

  @override
  Future<void> stopBloodPressure() async {
    _timer?.cancel();
    _measuring = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.close();
  }
}
