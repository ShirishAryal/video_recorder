import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:video_recorder_example/main.dart';

void main() {
  testWidgets('shows recording options', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('720p'), findsOneWidget);
    expect(find.text('Record audio'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Record video'), findsOneWidget);
  });
}
