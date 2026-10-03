import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_recorder/video_recorder.dart';

import 'fake_video_player_platform.dart';

void main() {
  late FakeVideoPlayerPlatform platform;

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  Future<void> pumpPlayer(
    WidgetTester tester,
    Widget player, {
    bool scrollable = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: scrollable ? ListView(children: [player]) : player,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('loads the file and plays on tap', (tester) async {
    await pumpPlayer(
      tester,
      RecordedVideoPlayer(file: XFile('/videos/a.mp4')),
      scrollable: true,
    );

    expect(platform.created.single, endsWith('/videos/a.mp4'));
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.text('00:03'), findsOneWidget); // length
    expect(platform.playing, isEmpty);

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();
    expect(platform.playing, hasLength(1));
    expect(find.byTooltip('Pause'), findsOneWidget);

    await tester.tap(find.byType(VideoPlayer));
    await tester.pumpAndSettle();
    expect(platform.playing, isEmpty);
  });

  testWidgets('autoPlay starts playing', (tester) async {
    await pumpPlayer(
      tester,
      RecordedVideoPlayer(file: XFile('/videos/a.mp4'), autoPlay: true),
    );
    expect(platform.playing, hasLength(1));
  });

  testWidgets('replays from the start once finished', (tester) async {
    await pumpPlayer(
      tester,
      RecordedVideoPlayer(file: XFile('/videos/a.mp4'), autoPlay: true),
    );

    platform.finish(platform.playing.single);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Replay'), findsOneWidget);

    await tester.tap(find.byTooltip('Replay'));
    await tester.pumpAndSettle();
    expect(platform.seeks.last, Duration.zero);
    expect(platform.playing, hasLength(1));
  });

  testWidgets('loads a new file when the file changes', (tester) async {
    await pumpPlayer(tester, RecordedVideoPlayer(file: XFile('/videos/a.mp4')));
    await pumpPlayer(tester, RecordedVideoPlayer(file: XFile('/videos/b.mp4')));

    expect(platform.created, hasLength(2));
    expect(platform.created.last, endsWith('/videos/b.mp4'));
  });

  testWidgets('says so when the file cannot be played', (tester) async {
    platform.failCreate = true;
    await pumpPlayer(tester, RecordedVideoPlayer(file: XFile('/videos/x.mp4')));

    expect(find.text("This video can't be played."), findsOneWidget);
  });

  testWidgets('Retry reloads a video that failed to open', (tester) async {
    platform.failCreate = true;
    await pumpPlayer(tester, RecordedVideoPlayer(file: XFile('/videos/x.mp4')));

    platform.failCreate = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text("This video can't be played."), findsNothing);
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(platform.created.single, endsWith('/videos/x.mp4'));
  });

  group('network', () {
    final url = Uri.parse('https://example.com/videos/talk.mp4');

    testWidgets('streams the URL with its headers', (tester) async {
      await pumpPlayer(
        tester,
        RecordedVideoPlayer.network(
          url,
          httpHeaders: const {'Authorization': 'Bearer token'},
        ),
      );

      expect(platform.created.single, url.toString());
      expect(platform.headers.single, {'Authorization': 'Bearer token'});
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.text('00:03'), findsOneWidget);
    });

    testWidgets('shows a spinner while buffering', (tester) async {
      await pumpPlayer(
        tester,
        RecordedVideoPlayer.network(url, autoPlay: true),
      );
      final id = platform.playing.single;

      platform.buffering(id, active: true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      platform.buffering(id, active: false);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('offers Retry when the stream drops mid-playback', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        RecordedVideoPlayer.network(url, autoPlay: true),
      );

      platform.failPlayback(platform.playing.single);
      await tester.pumpAndSettle();
      expect(find.text("This video can't be played."), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(platform.created, hasLength(2));
      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets('reloads when the URL or headers change', (tester) async {
      await pumpPlayer(tester, RecordedVideoPlayer.network(url));
      await pumpPlayer(
        tester,
        RecordedVideoPlayer.network(url, httpHeaders: const {'X-Token': '1'}),
      );
      await pumpPlayer(
        tester,
        RecordedVideoPlayer.network(Uri.parse('https://example.com/b.mp4')),
      );

      expect(platform.created, hasLength(3));
      expect(platform.created.last, 'https://example.com/b.mp4');
    });

    testWidgets('switches between a file and a URL', (tester) async {
      await pumpPlayer(
        tester,
        RecordedVideoPlayer(file: XFile('/videos/a.mp4')),
      );
      await pumpPlayer(tester, RecordedVideoPlayer.network(url));

      expect(platform.created, hasLength(2));
      expect(platform.created.last, url.toString());
    });
  });

  testWidgets('fits a limited height without overflowing', (tester) async {
    await pumpPlayer(
      tester,
      Center(
        child: SizedBox(
          width: 300,
          height: 150,
          child: RecordedVideoPlayer(file: XFile('/videos/a.mp4')),
        ),
      ),
    );

    // 150 tall minus 48 of controls leaves 102 for a 16:9 video.
    final video = tester.getSize(find.byType(VideoPlayer));
    expect(video.height, closeTo(102, 0.5));
    expect(video.width, closeTo(102 * 16 / 9, 0.5));
    expect(tester.takeException(), isNull);
  });
}
