part of 'recorded_video_player.dart';

/// Keeps preloaded network videos on disk, so they play again without the
/// network, also after the app restarts.
///
/// Give it to [VideoPreloader]: upcoming videos are downloaded whole into
/// it. A [RecordedVideoPlayer.network] given it (directly or through the
/// preloader) plays saved videos from disk; videos it streams aren't saved,
/// since that would download them twice. Call [download] to save one
/// yourself. Create one per key and share it, e.g. as a top-level `final`.
class VideoCache {
  /// Keeps at most [maxFiles] videos, and none unplayed for longer than
  /// [maxAge]. The least recently played ones go first.
  VideoCache({
    String key = 'video_recorder_videos',
    int maxFiles = 30,
    Duration maxAge = const Duration(days: 7),
  }) : this.withManager(
         CacheManager(
           Config(
             key,
             maxNrOfCacheObjects: maxFiles,
             stalePeriod: maxAge,
             fileService: _VideoFileService(),
           ),
         ),
       );

  @visibleForTesting
  VideoCache.withManager(this._manager);

  final BaseCacheManager _manager;
  final Map<Uri, _Download> _downloads = {};

  /// [url]'s saved file, or `null` if it isn't fully downloaded yet.
  Future<File?> cachedFile(Uri url) async {
    try {
      final info = await _manager.getFileFromCache(url.toString());
      final file = info?.file;
      return file != null && await file.exists() ? file : null;
    } catch (_) {
      return null;
    }
  }

  /// Downloads [url] whole and saves it. Asking again while it downloads
  /// joins the same download.
  Future<File> download(Uri url, {Map<String, String> httpHeaders = const {}}) {
    final download = _downloads[url] ??= _Download(
      _manager.getFileStream(
        url.toString(),
        headers: httpHeaders,
        withProgress: true,
      ),
      onDone: () => _downloads.remove(url),
    );
    return download.file;
  }

  /// Whether [url] is downloading and, at its speed so far, will finish
  /// within [time].
  bool _finishesWithin(Uri url, Duration time) =>
      _downloads[url]?.finishesWithin(time) ?? false;

  /// Deletes [url]'s saved file.
  Future<void> remove(Uri url) => _manager.removeFile(url.toString());

  /// Deletes every saved video.
  Future<void> clear() => _manager.emptyCache();
}

class _Download {
  _Download(Stream<FileResponse> responses, {required void Function() onDone}) {
    final done = Completer<File>();
    file = done.future;
    void finish() {
      if (!done.isCompleted) {
        done.completeError(StateError('Download ended without a file'));
      }
      onDone();
    }

    responses.listen(
      (response) {
        if (response is DownloadProgress) {
          _received = response.downloaded;
          _total = response.totalSize;
        } else if (response is FileInfo && !done.isCompleted) {
          done.complete(response.file);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) done.completeError(error, stackTrace);
        finish();
      },
      onDone: finish,
      cancelOnError: true,
    );
  }

  late final Future<File> file;
  final _elapsed = Stopwatch()..start();
  int _received = 0;
  int? _total;

  bool finishesWithin(Duration time) {
    final total = _total;
    // Without a size or any bytes yet, there's nothing to go on.
    if (total == null || _received == 0) return false;
    final left = total - _received;
    if (left <= 0) return true;
    final bytesPerMs = _received / math.max(_elapsed.elapsedMilliseconds, 1);
    return left / bytesPerMs <= time.inMilliseconds;
  }
}

/// Names saved files after the video type, which AVPlayer needs to open
/// them, even when the server sends a generic content type.
class _VideoFileService extends FileService {
  final _http = HttpFileService();

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async =>
      _VideoResponse(await _http.get(url, headers: headers), Uri.parse(url));
}

class _VideoResponse implements FileServiceResponse {
  _VideoResponse(this._response, this._url);

  final FileServiceResponse _response;
  final Uri _url;

  static const _videoExtensions = {'.mp4', '.m4v', '.mov', '.3gp', '.webm'};

  @override
  String get fileExtension {
    final fromType = _response.fileExtension;
    if (_videoExtensions.contains(fromType)) return fromType;
    final name = _url.pathSegments.isEmpty ? '' : _url.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final fromUrl = dot < 0 ? '' : name.substring(dot).toLowerCase();
    return _videoExtensions.contains(fromUrl) ? fromUrl : '.mp4';
  }

  @override
  Stream<List<int>> get content => _response.content;

  @override
  int? get contentLength => _response.contentLength;

  @override
  int get statusCode => _response.statusCode;

  @override
  DateTime get validTill => _response.validTill;

  @override
  String? get eTag => _response.eTag;
}
