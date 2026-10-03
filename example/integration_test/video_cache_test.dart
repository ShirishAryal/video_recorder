import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';

/// Needs internet access: downloads a sample clip, then plays it from disk.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a downloaded video plays from the cache', (tester) async {
    final cache = VideoCache(key: 'video_cache_test');
    final url = Uri.parse(
      'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
    );
    await tester.runAsync(() async {
      await cache.clear();
      expect(await cache.cachedFile(url), isNull);

      final file = await cache.download(url);
      expect(file.path, endsWith('.mp4'));
      expect(await file.length(), greaterThan(0));
      expect((await cache.cachedFile(url))?.path, file.path);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedVideoPlayer.network(url, cache: cache, autoPlay: true),
        ),
      ),
    );

    final player = find.byType(RecordedVideoPlayer);
    List<String> times() => find
        .descendant(of: player, matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where(RegExp(r'^\d\d:\d\d$').hasMatch)
        .toList();
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      final t = times();
      if (t.length == 2 && t.first != '00:00') break;
    }
    expect(times().first, isNot('00:00'), reason: 'playback moved');
    expect(find.text("This video can't be played."), findsNothing);

    await tester.runAsync(cache.clear);
  });
}
