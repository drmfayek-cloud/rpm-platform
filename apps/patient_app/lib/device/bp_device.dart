// Device-independent interface for blood pressure monitors.
//
// The rest of the app only talks to [BpDevice]. Implementations:
//   * Hc03AndroidDevice  — Linktop HC03 via the vendor Android SDK (pilot device)
//   * FakeBpDevice       — simulator for development, demos and tests
//   * UnsupportedDevice  — platforms without a device SDK yet (iOS until the SDK track lands)

/// Connection state, normalised from the vendor SDK's Bluetooth states.
enum DeviceConnection {
  unbound,       // SDK service not started
  bluetoothOff,
  disconnected,
  connecting,
  connected,     // linked, not yet ready for commands
  ready,         // notifications enabled: measurements can start
  notReady,
  unknown,
}

DeviceConnection connectionFromName(String? name) {
  switch (name) {
    case 'UNBOUND':
      return DeviceConnection.unbound;
    case 'BLUETOOTH_OFF':
      return DeviceConnection.bluetoothOff;
    case 'DISCONNECTED':
      return DeviceConnection.disconnected;
    case 'CONNECTING':
      return DeviceConnection.connecting;
    case 'CONNECTED':
      return DeviceConnection.connected;
    case 'READY':
      return DeviceConnection.ready;
    case 'NOT_READY':
      return DeviceConnection.notReady;
    default:
      return DeviceConnection.unknown;
  }
}

class ScannedDevice {
  const ScannedDevice({required this.mac, this.name, this.rssi});
  final String mac;
  final String? name;
  final int? rssi;

  factory ScannedDevice.fromMap(Map<dynamic, dynamic> m) => ScannedDevice(
        mac: (m['mac'] as String?) ?? '',
        name: m['name'] as String?,
        rssi: (m['rssi'] as num?)?.toInt(),
      );

  @override
  String toString() => '${name ?? 'Unknown'} ($mac, rssi ${rssi ?? '-'})';
}

/// One completed blood pressure measurement, as produced by the device SDK.
class BpResult {
  const BpResult({
    required this.systolic,
    required this.diastolic,
    required this.pulse,
    required this.measuredAt,
    this.deviceSn,
    this.firmwareVersion,
    this.sdkVersion,
  });

  final int systolic;
  final int diastolic;
  final int? pulse;
  final DateTime measuredAt;
  final String? deviceSn;
  final String? firmwareVersion;
  final String? sdkVersion;

  /// Plausibility check before a value is saved. Mirrors the database constraints.
  bool get isPlausible =>
      systolic >= 40 &&
      systolic <= 300 &&
      diastolic >= 20 &&
      diastolic <= 200 &&
      systolic > diastolic &&
      (pulse == null || (pulse! >= 20 && pulse! <= 250));

  @override
  String toString() => '$systolic/$diastolic mmHg, pulse ${pulse ?? '-'}';
}

enum BpFailureReason { leak, movement, calculation, lowBattery, notConnected, busy, other }

class DeviceStatus {
  const DeviceStatus({
    required this.connection,
    this.deviceSn,
    this.battery,
    this.charging = false,
    this.measuring = false,
    this.firmwareVersion,
    this.sdkVersion,
  });

  final DeviceConnection connection;
  final String? deviceSn;
  final int? battery;
  final bool charging;
  final bool measuring;
  final String? firmwareVersion;
  final String? sdkVersion;

  factory DeviceStatus.fromMap(Map<dynamic, dynamic> m) => DeviceStatus(
        connection: m['bound'] == false
            ? DeviceConnection.unbound
            : connectionFromName(m['bleStateName'] as String?),
        deviceSn: m['deviceSn'] as String?,
        battery: ((m['battery'] as num?)?.toInt() ?? -1) < 0 ? null : (m['battery'] as num).toInt(),
        charging: m['charging'] == true,
        measuring: m['measuring'] == true,
        firmwareVersion: m['firmwareVersion'] as String?,
        sdkVersion: m['sdkVersion'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
sealed class DeviceEvent {
  const DeviceEvent();

  /// Converts a raw event map from the platform channel. Unknown types become [DeviceLog].
  static DeviceEvent fromMap(Map<dynamic, dynamic> m) {
    switch (m['type']) {
      case 'serviceBound':
        return const DeviceReady();
      case 'status':
        return StatusChanged(DeviceStatus.fromMap(m));
      case 'bleState':
        return ConnectionChanged(connectionFromName(m['name'] as String?));
      case 'bluetoothOffRequest':
        return const ConnectionChanged(DeviceConnection.bluetoothOff);
      case 'bleNotSupported':
        return const DeviceErrorEvent('This phone does not support Bluetooth Low Energy');
      case 'scanResults':
        final list = (m['devices'] as List?) ?? const [];
        return ScanResults(list.whereType<Map>().map(ScannedDevice.fromMap).where((d) => d.mac.isNotEmpty).toList());
      case 'deviceInfo':
        return DeviceIdentified(m['deviceSn'] as String?);
      case 'deviceInfoFailed':
        return const DeviceIdentified(null);
      case 'battery':
        return BatteryChanged(
          level: (m['level'] as num?)?.toInt(),
          charging: m['charging'] == true,
          full: m['full'] == true,
        );
      case 'bpStarted':
        return const BpStarted();
      case 'bpResult':
        final ms = (m['measuredAtMillis'] as num?)?.toInt();
        return BpMeasured(BpResult(
          systolic: (m['systolic'] as num).toInt(),
          diastolic: (m['diastolic'] as num).toInt(),
          pulse: (m['pulse'] as num?)?.toInt(),
          measuredAt: ms == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(ms),
          deviceSn: m['deviceSn'] as String?,
          firmwareVersion: m['firmwareVersion'] as String?,
          sdkVersion: m['sdkVersion'] as String?,
        ));
      case 'bpError':
        switch (m['reason']) {
          case 'leak':
            return const BpFailed(BpFailureReason.leak);
          case 'movement':
            return const BpFailed(BpFailureReason.movement);
          case 'calculation':
            return const BpFailed(BpFailureReason.calculation);
          default:
            return const BpFailed(BpFailureReason.other);
        }
      case 'sdkError':
        return DeviceErrorEvent((m['message'] as String?) ?? 'Device SDK error');
      default:
        return DeviceLog('${m['type']}: $m');
    }
  }
}

class DeviceReady extends DeviceEvent {
  const DeviceReady();
}

class StatusChanged extends DeviceEvent {
  const StatusChanged(this.status);
  final DeviceStatus status;
}

class ConnectionChanged extends DeviceEvent {
  const ConnectionChanged(this.connection);
  final DeviceConnection connection;
}

class ScanResults extends DeviceEvent {
  const ScanResults(this.devices);
  final List<ScannedDevice> devices;
}

class DeviceIdentified extends DeviceEvent {
  const DeviceIdentified(this.deviceSn);
  final String? deviceSn; // null when the device ID could not be read
}

class BatteryChanged extends DeviceEvent {
  const BatteryChanged({this.level, required this.charging, required this.full});
  final int? level;
  final bool charging;
  final bool full;
}

class BpStarted extends DeviceEvent {
  const BpStarted();
}

class BpMeasured extends DeviceEvent {
  const BpMeasured(this.result);
  final BpResult result;
}

class BpFailed extends DeviceEvent {
  const BpFailed(this.reason);
  final BpFailureReason reason;
}

class DeviceErrorEvent extends DeviceEvent {
  const DeviceErrorEvent(this.message);
  final String message;
}

class DeviceLog extends DeviceEvent {
  const DeviceLog(this.message);
  final String message;
}

/// Thrown by commands; [reason] is set when the failure maps to a known cause.
class DeviceException implements Exception {
  DeviceException(this.code, this.message, {this.reason});
  final String code;
  final String message;
  final BpFailureReason? reason;
  @override
  String toString() => 'DeviceException($code): $message';
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------
abstract class BpDevice {
  /// Human-readable name of the implementation, shown in diagnostics.
  String get implementationName;

  /// False where no device SDK exists yet (readings must be taken on a hub phone).
  bool get supportsMeasurement;

  Stream<DeviceEvent> get events;

  /// Starts the vendor SDK. Call once, after Bluetooth permissions are granted.
  Future<void> initialize();

  Future<DeviceStatus> status();
  Future<void> openBluetooth();
  Future<void> startScan();
  Future<void> stopScan();
  Future<void> connect(String mac);
  Future<void> disconnect();

  /// Starts an upper-arm blood pressure measurement. Result arrives as [BpMeasured] or [BpFailed].
  Future<void> startBloodPressure();
  Future<void> stopBloodPressure();

  void dispose();
}
