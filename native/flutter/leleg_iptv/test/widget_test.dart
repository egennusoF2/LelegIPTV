import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:leleg_iptv/main.dart';

void main() {
  // media_kit native plugins require an app bundle, so this is covered by
  // flutter build/run instead of the regular widget-test host.
  testWidgets('renders native player prototype shell', (tester) async {
    MediaKit.ensureInitialized();
    await tester.pumpWidget(const LelegIptvNativeApp());

    expect(find.text('Leleg IPTV Native'), findsOneWidget);
    expect(find.text('Stream URL'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
  }, skip: true);
}
