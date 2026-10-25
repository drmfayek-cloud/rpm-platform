import 'dart:async';

import 'package:flutter/services.dart';

import 'bp_device.dart';

/// Linktop HC03 through the native Android bridge (android_overlay/kotlin/Hc03Bridge.kt).
class Hc03AndroidDevice implements BpDevice {
  Hc03AndroidDevice({MethodChannel? methods, EventChannel? events})
      : _methods = methods ?? const MethodChannel('rpm/hc03'),
        _eventChannel = events ?? const EventChannel('rpm/hc03/events');

  final MethodChannel _methods;
  final EventChannel _eventChannel;
  Stream<DeviceEvent>? _events;
  Completer<void>? _bound;
  StreamSubscription<DeviceEvent>? _bindWatch;

  @override
  String get implementationName => 'Linktop HC03 (Android SDK)';

  @override
  bool get supportsMeasurement => true;

  @override
  Stream<DeviceEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => DeviceEvent.fromMap(e as Map))
      .asBroadcastStream();

  @override
  Future<void> initialize() async {
    if (_bound != null) return _bound!.future;
    final bound = _bound = Completer<void>();
    _bindWatch = events.listen((e) {
      if (e is DeviceReady && !bound.isCompleted) bound.complete();
    });
    final alreadyBound = await _call<bool>('bind') ?? false;
    if (alreadyBound && !bound.isCompleted) bound.complete();
    return bound.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _bound = null;
      throw DeviceException('BIND_TIMEOUT', 'The device service did not start');
    });
  }

  @override
  Future<DeviceStatus> status() async {
    final m = await _call<Map>('status');
    return DeviceStatus.fromMap(m ?? const {});
  }

  @override
  Future<void> openBluetooth() => _call('openBluetooth');

  @override
  Future<void> startScan() => _call('startScan');

  @override
  Future<void> stopScan() => _call('stopScan');

  @override
  Future<void> connect(String mac) => _call('connect', {'mac': mac});

  @override
  Future<void> disconnect() => _call('disconnect');

  @override
  Future<void> startBloodPressure() => _call('startBp');

  @override
  Future<void> stopBloodPressure() => _call('stopBp');

  @override
  void dispose() {
    _bindWatch?.cancel();
  }

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _methods.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw DeviceException(e.code, e.message ?? e.code, reason: switch (e.code) {
        'LOW_BATTERY' => BpFailureReason.lowBattery,
        'NOT_CONNECTED' => BpFailureReason.notConnected,
        'BUSY' => BpFailureReason.busy,
        _ => null,
      });
    }
  }
}
