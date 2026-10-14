import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';
import 'package:video_recorder_example/main.dart';

/// Needs a camera, with camera and microphone permission already granted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (condition()) return;
    }
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .join(' | ');
    throw TestFailure('Timed out. On screen: $texts');
  }

  bool found(Finder finder) => finder.evaluate().isNotEmpty;

  testWidgets('records as HEVC and plays the returned file', (tester) async {
    await tester.pumpWidget(const ExampleApp());

    await tester.pumpAndSettle();

    final hevcSwitch = find.text('Convert to HEVC on save');
    await tester.ensureVisible(hevcSwitch);
    await tester.pumpAndSettle();
    await tester.tap(hevcSwitch);
    await tester.pumpAndSettle();
    final recordButton = find.text('Record video');
    await tester.ensureVisible(recordButton);
    await tester.pumpAndSettle();
    await tester.tap(recordButton);

    const noCamera = 'No camera was found on this device.';
    await pumpUntil(
      tester,
      () =>
          found(find.bySemanticsLabel('Record')) || found(find.text(noCamera)),
    );
    if (found(find.text(noCamera))) {
      markTestSkipped('No camera on this device (e.g. the iOS simulator).');
      return;
    }

    await tester.tap(find.bySemanticsLabel('Record'));
    await pumpUntil(tester, () => found(find.bySemanticsLabel('Pause')));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Done'));
    await pumpUntil(tester, () => found(find.text('Save')));
    await tester.tap(find.text('Save'));

    final player = find.byType(RecordedVideoPlayer);
    await pumpUntil(
      tester,
      () => found(player),
      timeout: const Duration(seconds: 60),
    );
    expect(find.textContaining('_hevc.mp4'), findsWidgets);

    List<String> times() => find
        .descendant(of: player, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where(RegExp(r'^\d\d:\d\d$').hasMatch)
        .toList();

    await pumpUntil(tester, () => found(find.byTooltip('Play')));
    await tester.ensureVisible(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(times().last, isNot('00:00'), reason: 'video has a length');

    await tester.tap(find.byTooltip('Play'));
    await pumpUntil(
      tester,
      () => times().first != '00:00',
      timeout: const Duration(seconds: 10),
    );
    expect(find.byTooltip('Pause'), findsOneWidget);
    // ignore: avoid_print
    print('PLAYER_RESULT times=${times()}');

    // `--dart-define=HOLD_SECONDS=n` keeps the app on screen at the end,
    // e.g. to take a screenshot.
    const hold = int.fromEnvironment('HOLD_SECONDS');
    if (hold > 0) {
      await tester.pump(const Duration(milliseconds: 1600));
      await Future<void>.delayed(const Duration(seconds: hold));
    }
  });
}
