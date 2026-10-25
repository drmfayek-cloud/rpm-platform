import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'bp_device.dart';
import 'fake_bp_device.dart';
import 'hc03_android_device.dart';
import 'unsupported_device.dart';

/// Build with `--dart-define=DEVICE=simulator` to use the simulator on any platform.
const _deviceOverride = String.fromEnvironment('DEVICE');

BpDevice createBpDevice() {
  if (_deviceOverride == 'simulator') return FakeBpDevice();
  if (!kIsWeb && Platform.isAndroid) return Hc03AndroidDevice();
  return UnsupportedDevice();
}
