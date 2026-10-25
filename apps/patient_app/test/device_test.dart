import 'package:flutter_test/flutter_test.dart';
import 'package:patient_app/device/bp_device.dart';
import 'package:patient_app/device/fake_bp_device.dart';

void main() {
  group('DeviceEvent.fromMap (platform channel contract with Hc03Bridge.kt)', () {
    test('bp result', () {
      final e = DeviceEvent.fromMap({
        'type': 'bpResult',
        'systolic': 142,
        'diastolic': 91,
        'pulse': 77,
        'deviceSn': 'abc123',
        'firmwareVersion': '1.2',
        'sdkVersion': 'BleDev 2.7.2',
        'measuredAtMillis': 1761400000000,
      });
      expect(e, isA<BpMeasured>());
      final r = (e as BpMeasured).result;
      expect([r.systolic, r.diastolic, r.pulse], [142, 91, 77]);
      expect(r.deviceSn, 'abc123');
      expect(r.measuredAt, DateTime.fromMillisecondsSinceEpoch(1761400000000));
      expect(r.isPlausible, isTrue);
    });

    test('bp errors map to reasons', () {
      expect((DeviceEvent.fromMap({'type': 'bpError', 'reason': 'leak', 'code': 0}) as BpFailed).reason,
          BpFailureReason.leak);
      expect((DeviceEvent.fromMap({'type': 'bpError', 'reason': 'movement', 'code': 1}) as BpFailed).reason,
          BpFailureReason.movement);
      expect((DeviceEvent.fromMap({'type': 'bpError', 'reason': 'calculation'}) as BpFailed).reason,
          BpFailureReason.calculation);
    });

    test('connection states', () {
      expect((DeviceEvent.fromMap({'type': 'bleState', 'state': 104, 'name': 'READY'}) as ConnectionChanged).connection,
          DeviceConnection.ready);
      expect((DeviceEvent.fromMap({'type': 'bleState', 'state': 101, 'name': 'DISCONNECTED'}) as ConnectionChanged)
          .connection, DeviceConnection.disconnected);
    });

    test('scan results drop entries without an address', () {
      final e = DeviceEvent.fromMap({
        'type': 'scanResults',
        'devices': [
          {'mac': 'AA:BB', 'name': 'HC03', 'rssi': -60},
          {'mac': null, 'name': 'ghost', 'rssi': -90},
        ],
      }) as ScanResults;
      expect(e.devices.map((d) => d.mac), ['AA:BB']);
    });

    test('status with no battery reading', () {
      final s = (DeviceEvent.fromMap({'type': 'status', 'bound': true, 'bleStateName': 'READY', 'battery': -1})
              as StatusChanged)
          .status;
      expect(s.connection, DeviceConnection.ready);
      expect(s.battery, isNull);
    });

    test('unknown events are logged, not dropped', () {
      expect(DeviceEvent.fromMap({'type': 'somethingNew'}), isA<DeviceLog>());
    });
  });

  test('implausible values are flagged', () {
    BpResult r(int s, int d) => BpResult(systolic: s, diastolic: d, pulse: 70, measuredAt: DateTime(2026));
    expect(r(80, 120).isPlausible, isFalse);
    expect(r(320, 90).isPlausible, isFalse);
    expect(r(120, 80).isPlausible, isTrue);
  });

  test('simulator runs the full flow', () async {
    final d = FakeBpDevice(measureDuration: const Duration(milliseconds: 10))..nextScenario = FakeScenario.urgentHigh;
    final events = <DeviceEvent>[];
    final sub = d.events.listen(events.add);
    await d.initialize();
    await d.startScan();
    await d.connect(FakeBpDevice.fakeDevices.first.mac);
    await d.startBloodPressure();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final result = events.whereType<BpMeasured>().single.result;
    expect(result.systolic, greaterThanOrEqualTo(180));
    expect(events.whereType<DeviceIdentified>().single.deviceSn, isNotNull);
    await sub.cancel();
    d.dispose();
  });

  test('simulator refuses to measure when not connected', () async {
    final d = FakeBpDevice();
    await d.initialize();
    expect(d.startBloodPressure(), throwsA(isA<DeviceException>()));
    d.dispose();
  });
}
