import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'video_recorder_options.dart';
import 'video_recorder_screen.dart';

abstract final class VideoRecorder {
  /// Returns `null` if the user closes the recorder without saving. The
  /// caller owns the returned file and should delete it when done.
  static Future<XFile?> record(
    BuildContext context, {
    VideoRecorderOptions options = const VideoRecorderOptions(),
  }) {
    return Navigator.of(context).push<XFile>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VideoRecorderScreen(options: options),
      ),
    );
  }
}
