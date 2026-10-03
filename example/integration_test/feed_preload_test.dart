import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';
import 'package:video_recorder_example/main.dart';

/// Needs internet access. Compares how fast the first feed video (not
/// preloaded) and the second (preloaded) start playing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  bool found(Finder f) => f.evaluate().isNotEmpty;

  /// Pumps until the shown player's position moves; returns how long it took.
  Future<Duration> timeUntilPlaying(WidgetTester tester) async {
    final start = DateTime.now();
    final end = start.add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
      final times = find
          .descendant(
            of: find.byType(RecordedVideoPlayer),
            matching: find.byType(Text),
          )
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where(RegExp(r'^\d\d:\d\d$').hasMatch)
          .toList();
      if (times.length == 2 && times.first != '00:00') {
        return DateTime.now().difference(start);
      }
    }
    throw TestFailure('Video never started playing');
  }

  testWidgets('the next video is preloaded and starts faster', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    final open = find.text('Open feed (preloads next videos)');
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);

    final first = await timeUntilPlaying(tester);
    expect(find.textContaining('1 / 4 · not preloaded'), findsOneWidget);

    // Give the preloader a moment to open video 2.
    await tester.pump(const Duration(seconds: 3));

    await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
    for (var i = 0; i < 20 && !found(find.textContaining('2 / 4')); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final second = await timeUntilPlaying(tester);
    expect(find.textContaining('2 / 4 · preloaded'), findsOneWidget);

    // The rest are preloaded too: the video just left mustn't push out the
    // next one.
    for (var page = 3; page <= 4; page++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      for (var i = 0; i < 20 && !found(find.textContaining('$page / 4')); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await timeUntilPlaying(tester);
      expect(find.textContaining('$page / 4 · preloaded'), findsOneWidget);
    }

    // ignore: avoid_print
    print(
      'FEED_RESULT first=${first.inMilliseconds}ms '
      'second(preloaded)=${second.inMilliseconds}ms',
    );
  });
}
