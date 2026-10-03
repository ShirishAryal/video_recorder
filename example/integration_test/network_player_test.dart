import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';
import 'package:video_recorder_example/main.dart';

/// Needs internet access: streams the sample URL the example app suggests.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('streams a video from a URL', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    final playUrl = find.text('Play URL');
    await tester.ensureVisible(playUrl);
    await tester.pumpAndSettle();
    await tester.tap(playUrl);

    final player = find.byType(RecordedVideoPlayer);
    await tester.pump();
    await tester.scrollUntilVisible(
      player,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(player);
    List<String> times() => find
        .descendant(of: player, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where(RegExp(r'^\d\d:\d\d$').hasMatch)
        .toList();

    // autoPlay is on, so the position should start moving.
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
      final t = times();
      if (t.length == 2 && t.first != '00:00') break;
    }
    expect(find.text("This video can't be played."), findsNothing);
    final t = times();
    expect(t, hasLength(2));
    expect(t.last, isNot('00:00'), reason: 'has a length');
    expect(t.first, isNot('00:00'), reason: 'is playing');
    // ignore: avoid_print
    print('NETWORK_RESULT times=$t');
  });
}
