import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests the Bluetooth permissions the HC03 SDK needs.
///  * Android 12+ (API 31+): "Nearby devices" — scan + connect.
///  * Android 11 and below: location (Android requires it for Bluetooth scans,
///    and location services must also be switched on).
Future<bool> requestBluetoothPermissions() async {
  if (!Platform.isAndroid) return true;
  final sdkInt = await const MethodChannel('rpm/hc03').invokeMethod<int>('androidSdkInt') ?? 31;

  if (sdkInt >= 31) {
    final s = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    return s.values.every((p) => p.isGranted);
  }
  return (await Permission.locationWhenInUse.request()).isGranted;
}
