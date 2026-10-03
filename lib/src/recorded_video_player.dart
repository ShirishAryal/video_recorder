import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:video_player/video_player.dart';

import 'playback_bar.dart';

part 'video_cache.dart';
part 'video_preloader.dart';

/// Takes the available width. When the height is limited too, the video
/// shrinks to fit.
class RecordedVideoPlayer extends StatefulWidget {
  const RecordedVideoPlayer({
    super.key,
    required XFile this.file,
    this.autoPlay = false,
    this.looping = false,
  }) : url = null,
       httpHeaders = const {},
       preloader = null,
       cache = null;

  /// Streams [url]. On Android and iOS it should be `https`; plain `http` is
  /// blocked by default.
  const RecordedVideoPlayer.network(
    Uri this.url, {
    super.key,
    this.httpHeaders = const {},
    this.autoPlay = false,
    this.looping = false,
    this.preloader,
    this.cache,
  }) : file = null;

  final XFile? file;
  final Uri? url;

  /// Sent with every request for [url], e.g. an `Authorization` header.
  final Map<String, String> httpHeaders;

  final bool autoPlay;

  final bool looping;

  /// Uses [url]'s video from here if it's already open, and hands it back,
  /// paused at the start, when this player goes away.
  final VideoPreloader? preloader;

  /// Plays [url] from here if it's downloaded; otherwise streams it without
  /// saving it. Defaults to [preloader]'s cache.
  final VideoCache? cache;

  @override
  State<RecordedVideoPlayer> createState() => _RecordedVideoPlayerState();
}

class _RecordedVideoPlayerState extends State<RecordedVideoPlayer> {
  VideoPlayerController? _controller;
  bool _failed = false;

  /// New for every open, so an open that finishes late knows it's stale.
  Object? _opening;

  /// Set when the video is borrowed and must go back, not be disposed.
  (VideoPreloader, Uri, _Preloaded)? _borrowedFrom;

  static const _controlsHeight = 48.0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(RecordedVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameSource =
        oldWidget.file?.path == widget.file?.path &&
        oldWidget.url == widget.url &&
        mapEquals(oldWidget.httpHeaders, widget.httpHeaders) &&
        identical(oldWidget.preloader, widget.preloader) &&
        identical(oldWidget.cache, widget.cache);
    if (!sameSource) {
      _close();
      _open();
    } else if (oldWidget.looping != widget.looping) {
      _controller?.setLooping(widget.looping);
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  Future<VideoPlayerController> _createController() async {
    if (widget.url case final url?) {
      return _openNetwork(
        url,
        widget.httpHeaders,
        widget.cache ?? widget.preloader?.cache,
      );
    }
    final path = widget.file!.path;
    // On the web, recorded files are blob: URLs.
    return kIsWeb
        ? VideoPlayerController.networkUrl(Uri.parse(path))
        : VideoPlayerController.file(File(path));
  }

  Future<void> _open() async {
    final opening = _opening = Object();
    _failed = false;
    final url = widget.url;
    final preloader = widget.preloader;
    final borrowed = url != null && preloader != null
        ? preloader._acquire(url, widget.httpHeaders)
        : null;
    _borrowedFrom = borrowed == null ? null : (preloader!, url!, borrowed);
    try {
      final controller = await (borrowed?.opening ?? _createController());
      if (_opening != opening) {
        // Closed meanwhile; a borrowed video was already given back.
        if (borrowed == null) controller.dispose();
        return;
      }
      _controller = controller;
      controller.addListener(_onChanged);
      if (mounted) setState(() {});
      await (borrowed?.ready ?? controller.initialize());
      if (_opening != opening) return;
      await controller.setLooping(widget.looping);
      if (widget.autoPlay) await controller.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted && _opening == opening) setState(() => _failed = true);
    }
  }

  void _close() {
    _opening = null;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_onChanged);
    if (_borrowedFrom case (final preloader, final url, final entry)) {
      preloader._release(url, entry);
    } else {
      controller?.dispose();
    }
    _borrowedFrom = null;
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {
      // Streams can also fail after they've started, e.g. on a dropped
      // connection.
      if (_controller?.value.hasError ?? false) _failed = true;
    });
  }

  void _retry() {
    _close();
    _open();
    setState(() {});
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = controller.value;
    if (value.isPlaying) {
      await controller.pause();
    } else {
      if (value.isCompleted || value.position >= value.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final controller = _controller;
          if (_failed) {
            return _Placeholder(
              constraints: constraints,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    "This video can't be played.",
                    style: TextStyle(color: Colors.white70),
                  ),
                  TextButton(
                    onPressed: _retry,
                    style: TextButton.styleFrom(foregroundColor: Colors.white),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }
          final value = controller?.value;
          if (controller == null || value == null || !value.isInitialized) {
            return _Placeholder(
              constraints: constraints,
              child: const CircularProgressIndicator(color: Colors.white),
            );
          }

          final maxVideoHeight = constraints.hasBoundedHeight
              ? (constraints.maxHeight - _controlsHeight).clamp(
                  0.0,
                  double.infinity,
                )
              : double.infinity;
          final (icon, label) = switch (value) {
            VideoPlayerValue(isPlaying: true) => (Icons.pause, 'Pause'),
            VideoPlayerValue(isCompleted: true) => (Icons.replay, 'Replay'),
            _ => (Icons.play_arrow, 'Play'),
          };

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxVideoHeight),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: value.aspectRatio,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        VideoPlayer(controller),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _togglePlayback,
                          // The big button is decoration; the labelled one
                          // below is what screen readers use.
                          child: value.isPlaying || value.isBuffering
                              ? null
                              : ExcludeSemantics(
                                  child: Center(child: _BigButton(icon: icon)),
                                ),
                        ),
                        if (value.isBuffering)
                          const IgnorePointer(
                            child: Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: _controlsHeight,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _togglePlayback,
                      icon: Icon(icon),
                      color: Colors.white,
                      tooltip: label,
                    ),
                    Expanded(
                      child: PlaybackBar(
                        player: controller,
                        padding: const EdgeInsets.only(right: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Holds a 16:9 space plus the controls row while there's no video to show.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.constraints, required this.child});

  final BoxConstraints constraints;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 320.0;
    var height = width * 9 / 16 + _RecordedVideoPlayerState._controlsHeight;
    if (constraints.hasBoundedHeight && constraints.maxHeight < height) {
      height = constraints.maxHeight;
    }
    return SizedBox(
      width: width,
      height: height,
      child: Center(child: child),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black54,
      ),
      child: Icon(icon, color: Colors.white, size: 40),
    );
  }
}

/// Opens [url] from [cache] if it's downloaded. Otherwise streams it, or,
/// with [waitForDownload], downloads it into [cache] and opens it from there.
Future<VideoPlayerController> _openNetwork(
  Uri url,
  Map<String, String> httpHeaders,
  VideoCache? cache, {
  bool waitForDownload = false,
}) async {
  // The web player can't open files.
  if (cache != null && !kIsWeb) {
    final file = await cache.cachedFile(url);
    if (file != null) return VideoPlayerController.file(file);
    if (waitForDownload) {
      final file = await cache.download(url, httpHeaders: httpHeaders);
      return VideoPlayerController.file(file);
    }
  }
  return VideoPlayerController.networkUrl(url, httpHeaders: httpHeaders);
}
