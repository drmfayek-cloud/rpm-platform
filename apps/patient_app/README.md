# Patient app (Flutter)

## Layout

- `lib/device/` — device layer. `bp_device.dart` is the interface the app uses; `hc03_android_device.dart`
  talks to the HC03; `fake_bp_device.dart` simulates one; `unsupported_device.dart` is used on iOS until
  the iOS SDK exists.
- `android_overlay/kotlin/` — the native Android bridge to the Linktop SDK (`Hc03Bridge.kt`).
- `vendor/` — Linktop BleDev SDK v2.7.2 (licensed; keep the repository private).
- `tool/patch_android.py` — adds the SDK, permissions and bridge to the generated Android project.

## Build locally (developer machine with Flutter + Android SDK)

```bash
cd apps/patient_app
flutter create --platforms=android --org health.rpm --project-name patient_app .
python3 tool/patch_android.py
flutter run                                   # real HC03
flutter run --dart-define=DEVICE=simulator    # simulated device
```

## SDK facts (verified against the compiled library, not the PDF)

- `MeasureType.BP == 1` (the PDF guide says 0).
- `bind(DeviceType.HealthMonitor, context, listener)`; listeners are registered in `onServiceBind()`.
- `connectToBle(BluetoothDevice)` — not a MAC string.
- `scan(true)` auto-connects to the first HC03 it finds; the app uses `autoScan(true)` and lets the user pick.
- Blood pressure errors: `onLeakError(0)` = cuff/tube leak, `onLeakError(1)` = movement/talking.
- The SDK refuses nothing at low battery; the bridge blocks measurement below 20% (vendor demo behaviour).
