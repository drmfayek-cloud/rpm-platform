import 'bp_device.dart';

/// Used on platforms without a device SDK (iOS until the iOS SDK track delivers).
/// The rest of the app still works; readings are taken on the patient's Android hub phone.
class UnsupportedDevice implements BpDevice {
  @override
  String get implementationName => 'Not available on this platform';

  @override
  bool get supportsMeasurement => false;

  @override
  Stream<DeviceEvent> get events => const Stream.empty();

  Never _unsupported() =>
      throw DeviceException('UNSUPPORTED', 'Readings with this device are not yet supported on this phone');

  @override
  Future<void> initialize() async {}

  @override
  Future<DeviceStatus> status() async => const DeviceStatus(connection: DeviceConnection.unbound);

  @override
  Future<void> openBluetooth() async => _unsupported();

  @override
  Future<void> startScan() async => _unsupported();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String mac) async => _unsupported();

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> startBloodPressure() async => _unsupported();

  @override
  Future<void> stopBloodPressure() async {}

  @override
  void dispose() {}
}
