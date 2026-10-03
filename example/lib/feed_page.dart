import 'package:flutter/material.dart';
import 'package:video_recorder/video_recorder.dart';

/// Shared by every feed, so watched videos play from disk next time.
final videoCache = VideoCache();

/// A vertical, swipe-to-advance feed that preloads the next two videos and
/// keeps the previous one open, so swiping back is instant too.
class FeedPage extends StatefulWidget {
  const FeedPage({super.key, required this.urls});

  final List<Uri> urls;

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final _preloader = VideoPreloader(maxIdle: 3, cache: videoCache);

  /// Whether each page's video was already open when the page was built,
  /// i.e. whether preloading did its job.
  final _wasPreloaded = <int, bool>{};

  @override
  void initState() {
    super.initState();
    _preloader.preload(widget.urls.skip(1).take(2));
  }

  @override
  void dispose() {
    _preloader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Feed'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: PageView.builder(
        scrollDirection: Axis.vertical,
        itemCount: widget.urls.length,
        onPageChanged: (i) =>
            _preloader.preload(widget.urls.skip(i + 1).take(2)),
        itemBuilder: (context, i) {
          final url = widget.urls[i];
          final preloaded = _wasPreloaded.putIfAbsent(
            i,
            () => _preloader.isPreloaded(url),
          );
          return Stack(
            children: [
              Center(
                child: RecordedVideoPlayer.network(
                  url,
                  key: ValueKey(url),
                  preloader: _preloader,
                  autoPlay: true,
                  looping: true,
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                child: Chip(
                  label: Text(
                    '${i + 1} / ${widget.urls.length} · '
                    '${preloaded ? 'preloaded' : 'not preloaded'}',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
