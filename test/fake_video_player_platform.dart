import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  final List<String> created = [];
  final Set<int> playing = {};
  final Map<int, StreamController<VideoEvent>> _events = {};
  final List<Duration> seeks = [];
  final List<Map<String, String>> headers = [];
  bool? looping;
  int _nextId = 0;

  void finish(int playerId) {
    playing.remove(playerId);
    _events[playerId]!.add(VideoEvent(eventType: VideoEventType.completed));
  }

  @override
  Future<void> init() async {}

  bool failCreate = false;

  void buffering(int playerId, {required bool active}) {
    _events[playerId]!.add(
      VideoEvent(
        eventType: active
            ? VideoEventType.bufferingStart
            : VideoEventType.bufferingEnd,
      ),
    );
  }

  /// Like a dropped connection after playback has started.
  void failPlayback(int playerId) {
    _events[playerId]!.addError(
      PlatformException(code: 'VideoError', message: 'connection lost'),
    );
  }

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (failCreate) {
      throw PlatformException(code: 'VideoError', message: 'unplayable');
    }
    created.add(options.dataSource.uri!);
    headers.add(options.dataSource.httpHeaders);
    return _nextId++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    // Like a platform event channel, the stream stays open after the
    // initialized event.
    final events = _events[playerId] = StreamController<VideoEvent>();
    scheduleMicrotask(
      () => events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 3),
          size: const Size(1280, 720),
        ),
      ),
    );
    return events.stream;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      this.looping = looping;

  @override
  Future<void> play(int playerId) async => playing.add(playerId);

  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async =>
      seeks.add(position);

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setPreventsDisplaySleepDuringVideoPlayback(
    int playerId,
    bool prevent,
  ) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.blue);

  final List<int> disposed = [];

  @override
  Future<void> dispose(int playerId) async {
    playing.remove(playerId);
    disposed.add(playerId);
  }
}
