import 'dart:async';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_recorder/video_recorder.dart';

import 'fake_video_player_platform.dart';

void main() {
  late FakeVideoPlayerPlatform platform;
  final a = Uri.parse('https://example.com/a.mp4');
  final b = Uri.parse('https://example.com/b.mp4');
  final c = Uri.parse('https://example.com/c.mp4');

  setUp(() {
    platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  /// video_player's dispose() finishes on the real event loop.
  Future<void> settleDisposals(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  Future<void> show(WidgetTester tester, Widget? player) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: player ?? const SizedBox())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('opens videos without playing them', (tester) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);

    preloader.preload([a, b]);
    await tester.pumpAndSettle();

    expect(platform.created, [a.toString(), b.toString()]);
    expect(platform.playing, isEmpty);
    expect(preloader.isPreloaded(a), isTrue);
    expect(preloader.isPreloaded(c), isFalse);
  });

  testWidgets('a player reuses the preloaded video', (tester) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);
    preloader.preload([a]);
    await tester.pumpAndSettle();

    await show(
      tester,
      RecordedVideoPlayer.network(a, preloader: preloader, autoPlay: true),
    );

    expect(platform.created, hasLength(1), reason: 'no second open');
    expect(platform.playing, hasLength(1));
    expect(find.byType(VideoPlayer), findsOneWidget);
  });

  testWidgets('gets the video back, paused at the start, when the player '
      'goes away', (tester) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);
    preloader.preload([a]);
    await tester.pumpAndSettle();

    await show(
      tester,
      RecordedVideoPlayer.network(a, preloader: preloader, autoPlay: true),
    );
    await show(tester, null);
    await settleDisposals(tester);

    expect(platform.disposed, isEmpty);
    expect(platform.playing, isEmpty);
    expect(platform.seeks.last, Duration.zero);
    expect(preloader.isPreloaded(a), isTrue);

    // Swiping back reuses it again.
    await show(tester, RecordedVideoPlayer.network(a, preloader: preloader));
    expect(platform.created, hasLength(1));
  });

  testWidgets('keeps at most maxIdle, releasing the oldest first', (
    tester,
  ) async {
    final preloader = VideoPreloader(maxIdle: 2);
    addTearDown(preloader.dispose);

    preloader.preload([a, b]);
    await tester.pumpAndSettle();
    preloader.preload([c]);
    await tester.pumpAndSettle();
    await settleDisposals(tester);

    expect(preloader.isPreloaded(a), isFalse);
    expect(preloader.isPreloaded(b), isTrue);
    expect(preloader.isPreloaded(c), isTrue);
    expect(platform.disposed, hasLength(1));
  });

  testWidgets("a video the user left doesn't push out the upcoming ones", (
    tester,
  ) async {
    final urls = [
      for (var i = 0; i < 6; i++) Uri.parse('https://example.com/$i.mp4'),
    ];
    final preloader = VideoPreloader(maxIdle: 2);
    addTearDown(preloader.dispose);
    final readyWhenShown = <int, bool>{};
    preloader.preload(urls.skip(1));
    await show(
      tester,
      PageView.builder(
        scrollDirection: Axis.vertical,
        itemCount: urls.length,
        onPageChanged: (i) => preloader.preload(urls.skip(i + 1)),
        itemBuilder: (context, i) {
          readyWhenShown.putIfAbsent(i, () => preloader.isPreloaded(urls[i]));
          return RecordedVideoPlayer.network(
            urls[i],
            key: ValueKey(i),
            preloader: preloader,
          );
        },
      ),
    );

    for (var i = 1; i < urls.length; i++) {
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.pumpAndSettle();
      await settleDisposals(tester);
    }

    expect(readyWhenShown, {
      0: false,
      for (var i = 1; i < urls.length; i++) i: true,
    });
  });

  testWidgets('preloads no more than maxIdle at once', (tester) async {
    final preloader = VideoPreloader(maxIdle: 1);
    addTearDown(preloader.dispose);

    preloader.preload([a, b, c]);
    await tester.pumpAndSettle();

    expect(platform.created, [a.toString()]);
  });

  testWidgets('the video being shown is never evicted', (tester) async {
    final preloader = VideoPreloader(maxIdle: 1);
    addTearDown(preloader.dispose);
    await show(tester, RecordedVideoPlayer.network(a, preloader: preloader));

    preloader.preload([b]);
    preloader.preload([c]);
    await tester.pumpAndSettle();
    await settleDisposals(tester);

    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(platform.disposed, hasLength(1), reason: 'only b was released');
    expect(preloader.isPreloaded(c), isTrue);
  });

  testWidgets('two players on one URL each get their own video', (
    tester,
  ) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);

    await show(
      tester,
      Column(
        children: [
          Expanded(child: RecordedVideoPlayer.network(a, preloader: preloader)),
          Expanded(child: RecordedVideoPlayer.network(a, preloader: preloader)),
        ],
      ),
    );

    expect(platform.created, hasLength(2));
    expect(find.byType(VideoPlayer), findsNWidgets(2));
  });

  testWidgets('a failed preload is replaced when a player asks for it', (
    tester,
  ) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);
    platform.failCreate = true;
    preloader.preload([a]);
    await tester.pumpAndSettle();

    platform.failCreate = false;
    await show(tester, RecordedVideoPlayer.network(a, preloader: preloader));

    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(platform.created, [a.toString()]);
  });

  testWidgets('different headers open the video again', (tester) async {
    final preloader = VideoPreloader();
    addTearDown(preloader.dispose);
    preloader.preload([a], httpHeaders: const {'Authorization': 'old'});
    await tester.pumpAndSettle();

    await show(
      tester,
      RecordedVideoPlayer.network(
        a,
        preloader: preloader,
        httpHeaders: const {'Authorization': 'new'},
      ),
    );

    expect(platform.headers.last, {'Authorization': 'new'});
    expect(platform.created, hasLength(2));
  });

  testWidgets('dispose releases idle videos now and shown ones later', (
    tester,
  ) async {
    final preloader = VideoPreloader();
    await show(tester, RecordedVideoPlayer.network(a, preloader: preloader));
    preloader.preload([b]);
    await tester.pumpAndSettle();

    preloader.dispose();
    await settleDisposals(tester);
    expect(platform.disposed, hasLength(1), reason: 'b');

    await show(tester, null);
    await settleDisposals(tester);
    expect(platform.disposed, hasLength(2), reason: 'a, once its player left');
  });

  group('with a cache', () {
    late FakeCacheManager manager;
    late VideoCache cache;
    setUp(() {
      manager = FakeCacheManager();
      cache = VideoCache.withManager(manager);
    });

    String fileUri(Uri url) => Uri.file(manager.pathFor(url)).toString();

    testWidgets('downloads upcoming videos whole and opens them from disk', (
      tester,
    ) async {
      final preloader = VideoPreloader(cache: cache);
      addTearDown(preloader.dispose);

      preloader.preload([a]);
      await tester.pumpAndSettle();
      expect(manager.downloads, [a]);
      expect(platform.created, isEmpty, reason: 'nothing streamed');
      expect(preloader.isPreloaded(a), isFalse);

      manager.finish(a);
      await tester.pumpAndSettle();
      expect(platform.created, [fileUri(a)]);
      expect(preloader.isPreloaded(a), isTrue);
    });

    testWidgets('a downloaded video plays from disk', (tester) async {
      manager.save(a);

      await show(tester, RecordedVideoPlayer.network(a, cache: cache));

      expect(platform.created, [fileUri(a)]);
      expect(manager.downloads, isEmpty);
      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets("a video that wasn't preloaded streams without being saved", (
      tester,
    ) async {
      await show(tester, RecordedVideoPlayer.network(a, cache: cache));

      expect(platform.created, [a.toString()]);
      expect(manager.downloads, isEmpty, reason: 'no second download');
    });

    testWidgets('a player streams a preload that is far from done', (
      tester,
    ) async {
      final preloader = VideoPreloader(cache: cache);
      addTearDown(preloader.dispose);
      preloader.preload([a]);
      await tester.pumpAndSettle();
      manager.progress(a, received: 1, total: 1 << 40);

      await show(tester, RecordedVideoPlayer.network(a, preloader: preloader));

      expect(platform.created, [a.toString()], reason: 'streamed');
      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets('a player waits for a preload that is nearly done', (
      tester,
    ) async {
      final preloader = VideoPreloader(cache: cache);
      addTearDown(preloader.dispose);
      preloader.preload([a]);
      await tester.pumpAndSettle();
      manager.progress(a, received: 99, total: 100);

      // The spinner never settles, so pump by hand.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RecordedVideoPlayer.network(a, preloader: preloader),
          ),
        ),
      );
      await tester.pump();
      expect(platform.created, isEmpty, reason: 'waiting, not streaming');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      manager.finish(a);
      await tester.pumpAndSettle();
      expect(platform.created, [fileUri(a)]);
      expect(find.byType(VideoPlayer), findsOneWidget);
    });

    testWidgets('a failed download is retried by the next preload', (
      tester,
    ) async {
      final preloader = VideoPreloader(cache: cache);
      addTearDown(preloader.dispose);
      preloader.preload([a]);
      await tester.pumpAndSettle();
      manager.fail(a);
      await tester.pumpAndSettle();

      preloader.preload([a]);
      await tester.pumpAndSettle();
      expect(manager.downloads, [a, a]);
      manager.finish(a);
      await tester.pumpAndSettle();

      expect(preloader.isPreloaded(a), isTrue);
    });
  });
}

class FakeCacheManager extends Fake implements BaseCacheManager {
  final _fs = MemoryFileSystem();
  final Map<Uri, StreamController<FileResponse>> _streams = {};
  final List<Uri> downloads = [];

  String pathFor(Uri url) => '/cache/${url.pathSegments.last}';

  File save(Uri url) => _fs.file(pathFor(url))..createSync(recursive: true);

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    final file = _fs.file(pathFor(Uri.parse(key)));
    return file.existsSync()
        ? FileInfo(file, FileSource.Cache, DateTime(2100), key)
        : null;
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    final uri = Uri.parse(url);
    downloads.add(uri);
    return (_streams[uri] = StreamController()).stream;
  }

  void progress(Uri url, {required int received, required int total}) =>
      _streams[url]!.add(DownloadProgress(url.toString(), total, received));

  void finish(Uri url) {
    final file = save(url);
    _streams.remove(url)!
      ..add(FileInfo(file, FileSource.Online, DateTime(2100), url.toString()))
      ..close();
  }

  void fail(Uri url) => _streams.remove(url)!
    ..addError(Exception('download failed'))
    ..close();
}
