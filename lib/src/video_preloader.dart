part of 'recorded_video_player.dart';

/// Opens upcoming network videos without playing them, so a
/// [RecordedVideoPlayer.network] given the same preloader starts instantly.
///
/// Without a [cache], opening fetches the MP4 index and a first chunk. How
/// much more a paused video keeps buffering is up to the platform player
/// (Android's can buffer tens of seconds), so keep [maxIdle] small on mobile
/// data. With a [cache], each video is downloaded whole and opened from
/// disk, and plays from disk next time too. A player that reaches a video
/// still downloading waits if it's nearly done and otherwise streams it.
class VideoPreloader {
  VideoPreloader({this.maxIdle = 2, this.cache}) : assert(maxIdle >= 0);

  /// How many open videos to keep while no player is showing them. The
  /// least recently requested ones are released first.
  final int maxIdle;

  /// Where downloaded videos are kept. Players given this preloader use it
  /// too.
  final VideoCache? cache;

  final Map<Uri, _Preloaded> _entries = {};

  /// The videos last asked for, which are released last.
  Set<Uri> _upcoming = {};
  int _clock = 0;
  bool _disposed = false;

  /// Starts opening [urls], in order, keeping at most [maxIdle] of them.
  /// Call it again as the user moves, e.g. with the next two in a feed.
  void preload(
    Iterable<Uri> urls, {
    Map<String, String> httpHeaders = const {},
  }) {
    if (_disposed) return;
    final wanted = urls.take(maxIdle).toList();
    for (final url in wanted) {
      var entry = _entries[url];
      if (entry != null &&
          !entry.inUse &&
          (entry.failed || !mapEquals(entry.httpHeaders, httpHeaders))) {
        _remove(url);
        entry = null;
      }
      entry ??= _create(url, httpHeaders, waitForDownload: true);
      entry.lastTouched = _clock++;
    }
    _upcoming = wanted.toSet();
    _evict();
  }

  /// Whether [url] is open and ready to play.
  bool isPreloaded(Uri url) =>
      _entries[url]?.controller?.value.isInitialized ?? false;

  /// Releases every video not currently shown; the rest are released when
  /// their players go away.
  void dispose() {
    _disposed = true;
    for (final url in [..._entries.keys]) {
      if (!_entries[url]!.inUse) _remove(url);
    }
  }

  _Preloaded _create(
    Uri url,
    Map<String, String> httpHeaders, {
    bool waitForDownload = false,
  }) {
    final entry = _Preloaded(
      httpHeaders,
      _openNetwork(url, httpHeaders, cache, waitForDownload: waitForDownload),
      waitsForDownload: waitForDownload && cache != null,
    );
    return _entries[url] = entry;
  }

  /// Hands [url]'s video to a player, or `null` if another player is
  /// already showing it (that player then opens its own).
  _Preloaded? _acquire(Uri url, Map<String, String> httpHeaders) {
    if (_disposed) return null;
    var entry = _entries[url];
    if (entry != null && entry.inUse) return null;
    if (entry != null &&
        (entry.failed ||
            !mapEquals(entry.httpHeaders, httpHeaders) ||
            _shouldStreamInstead(url, entry))) {
      _remove(url);
      entry = null;
    }
    entry ??= _create(url, httpHeaders);
    entry
      ..inUse = true
      ..lastTouched = _clock++;
    return entry;
  }

  /// Whether [entry] is still downloading and won't finish soon, so a
  /// player should stream [url] rather than wait. Streaming while it
  /// downloads uses the data twice, so a nearly done download is waited for.
  bool _shouldStreamInstead(Uri url, _Preloaded entry) =>
      entry.waitsForDownload &&
      entry.controller == null &&
      !(cache?._finishesWithin(url, _worthWaitingFor) ?? false);

  static const _worthWaitingFor = Duration(seconds: 1);

  /// Takes a video back from a player. It's kept, paused at the start,
  /// unless it failed or the preloader is disposed.
  void _release(Uri url, _Preloaded entry) {
    if (!identical(_entries[url], entry)) {
      entry.dispose();
      return;
    }
    entry.inUse = false;
    if (_disposed || entry.failed) {
      _remove(url);
      return;
    }
    entry.lastTouched = _clock++;
    _evict();
    // Often it's the one released, as the user moved on.
    if (!identical(_entries[url], entry)) return;
    final controller = entry.controller;
    if (controller != null && controller.value.isInitialized) {
      entry.rewinding = Future.wait([
        controller.pause(),
        controller.seekTo(Duration.zero),
      ]);
    }
  }

  /// Releases idle videos beyond [maxIdle], least recently requested first,
  /// sparing the upcoming ones so a video the user just left doesn't push
  /// out the next one.
  void _evict() {
    final idle =
        _entries.entries
            .where((e) => !e.value.inUse && !_upcoming.contains(e.key))
            .toList()
          ..sort((a, b) => a.value.lastTouched.compareTo(b.value.lastTouched));
    var idleCount = _entries.values.where((e) => !e.inUse).length;
    for (final candidate in idle) {
      if (idleCount <= maxIdle) break;
      _remove(candidate.key);
      idleCount--;
    }
  }

  void _remove(Uri url) => _entries.remove(url)?.dispose();
}

class _Preloaded {
  _Preloaded(this.httpHeaders, this.opening, {required this.waitsForDownload}) {
    ready = opening.then((c) {
      controller = c;
      return c.initialize();
    });
    // A player awaiting [ready] reports the error; this only records it.
    ready.then(
      (_) {},
      onError: (Object _) {
        initFailed = true;
      },
    );
  }

  final Map<String, String> httpHeaders;

  /// Resolves once the video is found in the cache or downloaded, or right
  /// away when streamed.
  final Future<VideoPlayerController> opening;
  late final Future<void> ready;

  /// Whether [opening] waits for a whole download.
  final bool waitsForDownload;

  VideoPlayerController? controller;
  bool inUse = false;
  bool initFailed = false;
  int lastTouched = 0;

  /// Pausing and seeking back to the start; disposing waits for it, since
  /// a seek that lands afterwards would use the disposed controller.
  Future<void>? rewinding;

  // initialize() can throw before the controller records an error.
  bool get failed => initFailed || (controller?.value.hasError ?? false);

  void dispose() => opening.then((c) async {
    await rewinding?.catchError((Object _) => <void>[]);
    await c.dispose();
  }, onError: (Object _) {});
}
