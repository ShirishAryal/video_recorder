import 'package:camera/camera.dart';

/// Resolutions are approximate: the platform picks the closest size the
/// camera supports.
enum VideoQuality {
  p480(ResolutionPreset.medium, 1200000, 700000),
  p720(ResolutionPreset.high, 2500000, 1500000),
  p1080(ResolutionPreset.veryHigh, 5000000, 3000000),
  p2160(ResolutionPreset.ultraHigh, 16000000, 10000000);

  const VideoQuality(this.preset, this.videoBitrate, this.hevcBitrate);

  final ResolutionPreset preset;

  /// Default recording bitrate, in bits per second.
  final int videoBitrate;

  /// Default HEVC conversion bitrate, in bits per second.
  final int hevcBitrate;
}
