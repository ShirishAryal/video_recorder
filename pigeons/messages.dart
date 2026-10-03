// After editing, regenerate with: dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'video_recorder',
    kotlinOut:
        'android/src/main/kotlin/com/example/video_recorder/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.example.video_recorder',
      errorClassName: 'HevcError',
    ),
    swiftOut: 'ios/video_recorder/Sources/video_recorder/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'HevcError'),
  ),
)
/// Failures are thrown as errors rather than returned as a status.
enum NativeConversionStatus { converted, alreadyHevc, unsupported, cancelled }

class ConversionRequest {
  ConversionRequest({
    required this.id,
    required this.inputPath,
    required this.outputPath,
    required this.bitrate,
  });

  int id;
  String inputPath;
  String outputPath;

  /// In bits per second.
  int bitrate;
}

class ConversionReply {
  ConversionReply({required this.status, this.reason});

  NativeConversionStatus status;
  String? reason;
}

@HostApi()
abstract class HevcConverterHostApi {
  /// Throws `conversion_failed` or `invalid_input` on failure.
  @async
  ConversionReply convert(ConversionRequest request);

  /// The pending `convert` call then returns `cancelled`.
  void cancel(int id);
}

@FlutterApi()
abstract class HevcConverterFlutterApi {
  /// [progress] is 0.0–1.0.
  void onProgress(int id, double progress);
}
