import 'package:flutter_test/flutter_test.dart';
import 'package:patient_app/device/fake_bp_device.dart';
import 'package:patient_app/main.dart';

void main() {
  testWidgets('device test bench starts with the simulator', (tester) async {
    await tester.pumpWidget(DeviceTestApp(device: FakeBpDevice()));
    expect(find.text('HC03 device test'), findsOneWidget);
    expect(find.text('Simulator'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(find.text('Find devices'), findsOneWidget);
  });
}
