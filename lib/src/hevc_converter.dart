import 'dart:async';
import 'dart:io' show File, FileSystemException;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'messages.g.dart';

enum HevcConversionStatus {
  converted,
  alreadyHevc,
  unsupported,
  notSmaller,
  cancelled,
  failed,
}

class HevcConversionResult {
  const HevcConversionResult({
    required this.file,
    required this.status,
    this.reason,
  });

  /// The converted video, or the original when conversion didn't happen.
  final XFile file;

  final HevcConversionStatus status;
  final String? reason;

  bool get converted => status == HevcConversionStatus.converted;
}

/// Converts videos to HEVC on the device. Whenever conversion isn't possible
/// or doesn't make the file smaller, the result points at the original.
abstract final class HevcConverter {
  @visibleForTesting
  static HevcConverterHostApi hostApi = HevcConverterHostApi();

  static int _nextId = 0;
  static final _progress = _ProgressRouter();
  static bool _progressSetUp = false;

  /// [bitrate] is in bits per second. The output is written next to [input],
  /// and [input] is never deleted; that's up to the caller.
  static Future<HevcConversionResult> convert(
    XFile input, {
    required int bitrate,
    void Function(double progress)? onProgress,
    Future<void>? cancel,
  }) async {
    HevcConversionResult keep(HevcConversionStatus status, [String? reason]) =>
        HevcConversionResult(file: input, status: status, reason: reason);

    if (kIsWeb) {
      return keep(
        HevcConversionStatus.unsupported,
        'Not available on the web.',
      );
    }

    final id = _nextId++;
    final output = _outputPathFor(input.path);
    if (!_progressSetUp) {
      HevcConverterFlutterApi.setUp(_progress);
      _progressSetUp = true;
    }
    if (onProgress != null) _progress.listeners[id] = onProgress;
    unawaited(cancel?.then((_) => hostApi.cancel(id)).catchError((_) {}));

    try {
      final reply = await hostApi.convert(
        ConversionRequest(
          id: id,
          inputPath: input.path,
          outputPath: output,
          bitrate: bitrate,
        ),
      );
      switch (reply.status) {
        case NativeConversionStatus.converted:
          break;
        case NativeConversionStatus.alreadyHevc:
          return keep(HevcConversionStatus.alreadyHevc, reply.reason);
        case NativeConversionStatus.unsupported:
          return keep(HevcConversionStatus.unsupported, reply.reason);
        case NativeConversionStatus.cancelled:
          return keep(HevcConversionStatus.cancelled, reply.reason);
      }
    } on PlatformException catch (e) {
      // Pigeon reports a missing native implementation as `channel-error`.
      if (e.code == 'channel-error') {
        return keep(
          HevcConversionStatus.unsupported,
          'Not available on this platform.',
        );
      }
      _deleteQuietly(output);
      return keep(HevcConversionStatus.failed, e.message ?? e.code);
    } finally {
      _progress.listeners.remove(id);
    }

    final int before, after;
    try {
      (before, after) = (
        File(input.path).lengthSync(),
        File(output).lengthSync(),
      );
    } on FileSystemException catch (e) {
      _deleteQuietly(output);
      return keep(HevcConversionStatus.failed, e.message);
    }
    if (after >= before) {
      _deleteQuietly(output);
      return keep(
        HevcConversionStatus.notSmaller,
        'The HEVC file ($after bytes) was not smaller than the original '
        '($before bytes).',
      );
    }
    return HevcConversionResult(
      file: XFile(output, mimeType: 'video/mp4'),
      status: HevcConversionStatus.converted,
    );
  }

  static String _outputPathFor(String input) {
    final slash = input.lastIndexOf('/');
    final dot = input.lastIndexOf('.');
    final stem = dot > slash ? input.substring(0, dot) : input;
    return '${stem}_hevc.mp4';
  }

  static void _deleteQuietly(String path) {
    File(path).delete().ignore();
  }
}

class _ProgressRouter implements HevcConverterFlutterApi {
  final Map<int, void Function(double)> listeners = {};

  @override
  void onProgress(int id, double progress) => listeners[id]?.call(progress);
}
