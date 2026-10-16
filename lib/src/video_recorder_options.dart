import 'package:camera/camera.dart';

import 'video_quality.dart';

class VideoRecorderOptions {
  const VideoRecorderOptions({
    this.quality = VideoQuality.p720,
    this.enableAudio = true,
    this.preferredLens = CameraLensDirection.back,
    this.maxDuration,
    this.hints = const [],
    this.countdownSeconds = 3,
    this.videoBitrate,
    this.audioBitrate,
    this.convertToHevc = false,
    this.hevcBitrate,
    this.optimizeForStreaming = true,
  }) : assert(
         hevcBitrate == null || hevcBitrate > 0,
         'hevcBitrate must be null or greater than zero',
       ),
       assert(
         videoBitrate == null || videoBitrate > 0,
         'videoBitrate must be null or greater than zero',
       ),
       assert(
         audioBitrate == null || audioBitrate > 0,
         'audioBitrate must be null or greater than zero',
       );

  final VideoQuality quality;
  final bool enableAudio;

  /// Falls back to the first available camera if none faces this way.
  final CameraLensDirection preferredLens;

  final Duration? maxDuration;

  /// Shown one at a time; the user steps through them while recording.
  final List<RecorderHint> hints;

  /// `0` starts recording as soon as Record is tapped.
  final int countdownSeconds;

  /// In bits per second. `null` uses [VideoQuality.videoBitrate].
  final int? videoBitrate;

  int get effectiveVideoBitrate => videoBitrate ?? quality.videoBitrate;

  /// In bits per second. `null` uses the device's default.
  final int? audioBitrate;

  /// Converts the take to HEVC on Save, returning the original if that isn't
  /// possible or doesn't help. HEVC doesn't play in every desktop browser.
  final bool convertToHevc;

  /// In bits per second. `null` uses [VideoQuality.hevcBitrate].
  final int? hevcBitrate;

  int get effectiveHevcBitrate => hevcBitrate ?? quality.hevcBitrate;

  /// Moves the MP4 index to the front on Save, so the uploaded video can
  /// start playing before it has fully downloaded. No re-encoding.
  final bool optimizeForStreaming;
}

/// A prompt shown while recording: a short [title] with an optional, longer
/// [description] under it.
class RecorderHint {
  const RecorderHint(this.title, {this.description});

  final String title;
  final String? description;
}
