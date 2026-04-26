import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:legoagent/main.dart';

void main() {
  testWidgets('idle screen renders with Scan button', (tester) async {
    await tester.pumpWidget(const LegoAgentApp());
    expect(find.byType(LegoAgentApp), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
  });
}
