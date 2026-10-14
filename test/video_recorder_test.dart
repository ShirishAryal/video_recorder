import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_recorder/src/messages.g.dart';
import 'package:video_recorder/video_recorder.dart';

import 'fake_hevc_host_api.dart';
import 'fake_video_player_platform.dart';

const _back = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);
const _front = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);

class FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  FakeCameraPlatform({this.cameras = const [_back, _front]});

  final List<CameraDescription> cameras;

  /// Real files, because the HEVC step compares file sizes.
  final Directory takes = Directory.systemTemp.createTempSync('takes');

  /// What each take contains; 1000 zero bytes (not an MP4) by default.
  List<int>? takeBytes;
  final List<CameraDescription> opened = [];
  final List<MediaSettings?> settings = [];
  int recordingsStarted = 0;
  int recordingsStopped = 0;
  int pauses = 0;
  int resumes = 0;

  final _initialized = StreamController<CameraInitializedEvent>.broadcast();
  int _nextId = 0;

  @override
  Future<List<CameraDescription>> availableCameras() async => cameras;

  @override
  Future<int> createCameraWithSettings(
    CameraDescription description,
    MediaSettings? mediaSettings,
  ) async {
    opened.add(description);
    settings.add(mediaSettings);
    return _nextId++;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    scheduleMicrotask(
      () => _initialized.add(
        CameraInitializedEvent(
          cameraId,
          1280,
          720,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream.where((e) => e.cameraId == cameraId);

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      StreamController<CameraErrorEvent>.broadcast().stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    recordingsStarted++;
  }

  @override
  Future<void> pauseVideoRecording(int cameraId) async => pauses++;

  @override
  Future<void> resumeVideoRecording(int cameraId) async => resumes++;

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    recordingsStopped++;
    final take = File('${takes.path}/take_$recordingsStopped.mp4')
      ..writeAsBytesSync(takeBytes ?? List.filled(1000, 0));
    return XFile(take.path);
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.grey);

  @override
  Future<void> dispose(int cameraId) async {}
}

class _Host extends StatefulWidget {
  const _Host({this.options = const VideoRecorderOptions()});

  final VideoRecorderOptions options;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  XFile? result;
  bool returned = false;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final file = await VideoRecorder.record(
          context,
          options: widget.options,
        );
        setState(() {
          result = file;
          returned = true;
        });
      },
      child: const Text('open'),
    );
  }
}

Future<_HostState> _openRecorder(
  WidgetTester tester, {
  VideoRecorderOptions options = const VideoRecorderOptions(),
}) async {
  await tester.pumpWidget(MaterialApp(home: _Host(options: options)));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host, skipOffstage: false));
}

/// Also waits out the default 3-second countdown.
Future<void> _tapRecord(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Record'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  await tester.pump();
}

Future<void> _tapStop(WidgetTester tester) async {
  await tester.tap(find.text('Done'));
  await tester.pumpAndSettle();
}

void main() {
  late FakeCameraPlatform platform;
  late FakeVideoPlayerPlatform player;

  setUp(() {
    platform = FakeCameraPlatform();
    CameraPlatform.instance = platform;
    player = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = player;
  });

  test('VideoQuality maps to camera presets', () {
    expect(VideoQuality.p480.preset, ResolutionPreset.medium);
    expect(VideoQuality.p720.preset, ResolutionPreset.high);
    expect(VideoQuality.p1080.preset, ResolutionPreset.veryHigh);
    expect(VideoQuality.p2160.preset, ResolutionPreset.ultraHigh);
  });

  testWidgets('opens the back camera at 720p by default', (tester) async {
    await _openRecorder(tester);

    expect(platform.opened.single, _back);
    expect(platform.settings.single?.resolutionPreset, ResolutionPreset.high);
    expect(platform.settings.single?.enableAudio, isTrue);
  });

  testWidgets('honours preferred lens and quality', (tester) async {
    await _openRecorder(
      tester,
      options: const VideoRecorderOptions(
        quality: VideoQuality.p1080,
        preferredLens: CameraLensDirection.front,
        enableAudio: false,
      ),
    );

    expect(platform.opened.single, _front);
    expect(
      platform.settings.single?.resolutionPreset,
      ResolutionPreset.veryHigh,
    );
    expect(platform.settings.single?.enableAudio, isFalse);
    expect(platform.settings.single?.videoBitrate, 5000000);
  });

  testWidgets('passes bitrates to the camera', (tester) async {
    await _openRecorder(
      tester,
      options: const VideoRecorderOptions(
        videoBitrate: 2500000,
        audioBitrate: 128000,
      ),
    );

    expect(platform.settings.single?.videoBitrate, 2500000);
    expect(platform.settings.single?.audioBitrate, 128000);
  });

  testWidgets('uses 2.5 Mbps video by default at 720p', (tester) async {
    await _openRecorder(tester);

    expect(platform.settings.single?.videoBitrate, 2500000);
    expect(platform.settings.single?.audioBitrate, isNull);
  });

  test('default video bitrate follows quality', () {
    int bitrate(VideoQuality q) =>
        VideoRecorderOptions(quality: q).effectiveVideoBitrate;

    expect(bitrate(VideoQuality.p480), 1200000);
    expect(bitrate(VideoQuality.p720), 2500000);
    expect(bitrate(VideoQuality.p1080), 5000000);
    expect(bitrate(VideoQuality.p2160), 16000000);
    expect(
      const VideoRecorderOptions(
        quality: VideoQuality.p1080,
        videoBitrate: 3000000,
      ).effectiveVideoBitrate,
      3000000,
    );
  });

  testWidgets('keeps bitrates after switching camera', (tester) async {
    await _openRecorder(
      tester,
      options: const VideoRecorderOptions(videoBitrate: 2500000),
    );
    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();

    expect(platform.opened.last, _front);
    expect(platform.settings.last?.videoBitrate, 2500000);
  });

  test('rejects non-positive bitrates', () {
    expect(() => VideoRecorderOptions(videoBitrate: 0), throwsAssertionError);
    expect(() => VideoRecorderOptions(audioBitrate: -1), throwsAssertionError);
  });

  testWidgets('switch camera flips between back and front', (tester) async {
    await _openRecorder(tester);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(platform.opened.last, _front);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(platform.opened.last, _back);
  });

  testWidgets('capture then save returns the recorded file', (tester) async {
    final host = await _openRecorder(tester);

    await _tapRecord(tester);
    expect(platform.recordingsStarted, 1);
    expect(find.byTooltip('Switch camera'), findsNothing);

    await _tapStop(tester);
    expect(platform.recordingsStopped, 1);
    expect(player.created.single, endsWith('take_1.mp4'));
    expect(player.playing, hasLength(1));

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(player.playing, isEmpty);
    expect(find.bySemanticsLabel('Play'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(host.returned, isTrue);
    expect(host.result?.path, endsWith('/take_1.mp4'));
  });

  group('optimizeForStreaming', () {
    Future<void> recordAndSave(WidgetTester tester) async {
      await _tapRecord(tester);
      await _tapStop(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('returns a copy with the index moved to the front', (
      tester,
    ) async {
      platform.takeBytes = File(
        'test/fixtures/moov_last.mp4',
      ).readAsBytesSync();
      final host = await _openRecorder(tester);

      await recordAndSave(tester);

      final saved = host.result!;
      expect(saved.path, endsWith('/take_1_streamable.mp4'));
      expect(await StreamableMp4.isStreamable(saved), isTrue);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(
        File('${platform.takes.path}/take_1.mp4').existsSync(),
        isFalse,
        reason: 'the original take is deleted',
      );
    });

    testWidgets('returns the take as-is when turned off', (tester) async {
      platform.takeBytes = File(
        'test/fixtures/moov_last.mp4',
      ).readAsBytesSync();
      final host = await _openRecorder(
        tester,
        options: const VideoRecorderOptions(optimizeForStreaming: false),
      );

      await recordAndSave(tester);

      expect(host.result?.path, endsWith('/take_1.mp4'));
      expect(await StreamableMp4.isStreamable(host.result!), isFalse);
    });
  });

  group('HEVC conversion on save', () {
    const options = VideoRecorderOptions(convertToHevc: true);
    late FakeHevcHostApi native;

    void fakeConverter({
      Future<ConversionReply> Function(ConversionRequest request)? reply,
    }) {
      native = FakeHevcHostApi(reply: reply);
      HevcConverter.hostApi = native;
      addTearDown(() => HevcConverter.hostApi = HevcConverterHostApi());
    }

    Future<void> recordAndSave(WidgetTester tester) async {
      await _tapRecord(tester);
      await _tapStop(tester);
      await tester.tap(find.text('Save'));
      await tester.pump();
    }

    testWidgets('returns the HEVC file at the default 1.5 Mbps', (
      tester,
    ) async {
      fakeConverter();
      final host = await _openRecorder(tester, options: options);

      await recordAndSave(tester);
      await tester.pumpAndSettle();

      expect(host.result?.path, endsWith('/take_1_hevc.mp4'));
      final request = native.requests.single;
      expect(request.bitrate, 1500000);
      expect(request.inputPath, endsWith('/take_1.mp4'));
    });

    testWidgets('shows progress while compressing', (tester) async {
      final finish = Completer<ConversionReply>();
      fakeConverter(reply: (_) => finish.future);
      await _openRecorder(tester, options: options);

      await recordAndSave(tester);
      expect(find.text('Compressing…'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Skip'), findsOneWidget);

      await sendProgress(
        tester.binding.defaultBinaryMessenger,
        native.requests.single.id,
        0.42,
      );
      await tester.pump();
      expect(find.text('Compressing… 42%'), findsOneWidget);

      finish.complete(
        ConversionReply(status: NativeConversionStatus.unsupported),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('Skip returns the original take', (tester) async {
      fakeConverter(
        reply: (_) async {
          await native.cancelRequested.future;
          return ConversionReply(status: NativeConversionStatus.cancelled);
        },
      );
      final host = await _openRecorder(tester, options: options);

      await recordAndSave(tester);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(native.cancelled, [native.requests.single.id]);
      expect(host.result?.path, endsWith('/take_1.mp4'));
    });

    testWidgets('falls back to the original when unsupported', (tester) async {
      fakeConverter(
        reply: (_) async => ConversionReply(
          status: NativeConversionStatus.unsupported,
          reason: 'no encoder',
        ),
      );
      final host = await _openRecorder(tester, options: options);

      await recordAndSave(tester);
      await tester.pumpAndSettle();

      expect(host.result?.path, endsWith('/take_1.mp4'));
    });

    testWidgets('does nothing when convertToHevc is off', (tester) async {
      fakeConverter();
      final host = await _openRecorder(tester);

      await recordAndSave(tester);
      await tester.pumpAndSettle();

      expect(native.requests, isEmpty);
      expect(host.result?.path, endsWith('/take_1.mp4'));
    });
  });

  testWidgets('every control has a label', (tester) async {
    await _openRecorder(tester);
    expect(find.bySemanticsLabel('Record'), findsOneWidget);
    expect(find.byTooltip('Switch camera'), findsOneWidget);
    expect(find.byTooltip('Timer 3s'), findsOneWidget);
    expect(find.byTooltip('Light off'), findsOneWidget);
    // Shown but dimmed until there is a take.
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await _tapRecord(tester);
    expect(find.text('Restart'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);

    await _tapStop(tester);
    expect(find.text('Re-record'), findsOneWidget);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget); // preview is playing
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('pause and resume recording', (tester) async {
    final host = await _openRecorder(tester);
    await _tapRecord(tester);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(platform.pauses, 1);
    expect(find.bySemanticsLabel('Resume'), findsOneWidget);
    expect(find.textContaining('Paused'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Resume'));
    await tester.pump();
    expect(platform.resumes, 1);
    expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    expect(find.textContaining('Paused'), findsNothing);

    await _tapStop(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(host.result?.path, endsWith('/take_1.mp4'));
  });

  testWidgets('stopping while paused still returns the take', (tester) async {
    final host = await _openRecorder(tester);
    await _tapRecord(tester);
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();

    await _tapStop(tester);
    expect(find.text('Save'), findsOneWidget);
    expect(find.textContaining('Paused'), findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(host.result, isNotNull);
  });

  group('hints', () {
    const hints = VideoRecorderOptions(
      hints: ['Introduce yourself', 'Describe the problem', 'Say thanks'],
    );

    testWidgets('are not shown when none are passed', (tester) async {
      await _openRecorder(tester);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('sit just above the record button', (tester) async {
      await _openRecorder(tester, options: hints);

      final hintBottom = tester.getBottomLeft(find.text('Next')).dy;
      final recordTop = tester.getTopLeft(find.bySemanticsLabel('Record')).dy;
      final screenMiddle = tester.getSize(find.byType(Scaffold)).height / 2;

      expect(hintBottom, lessThan(recordTop));
      expect(hintBottom, greaterThan(screenMiddle));
    });

    testWidgets('step through with next', (tester) async {
      await _openRecorder(tester, options: hints);

      expect(find.text('Introduce yourself'), findsOneWidget);
      expect(find.bySemanticsLabel('Hint 1 of 3'), findsOneWidget);

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Describe the problem'), findsOneWidget);
      expect(find.bySemanticsLabel('Hint 2 of 3'), findsOneWidget);

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Say thanks'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('swipe moves between hints', (tester) async {
      await _openRecorder(tester, options: hints);

      await tester.fling(
        find.text('Introduce yourself'),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Hint 2 of 3'), findsOneWidget);

      await tester.fling(
        find.text('Describe the problem'),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Hint 1 of 3'), findsOneWidget);
    });

    testWidgets('can be changed while recording and hide in review', (
      tester,
    ) async {
      await _openRecorder(tester, options: hints);
      await _tapRecord(tester);

      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Describe the problem'), findsOneWidget);
      expect(platform.recordingsStopped, 0);

      await _tapStop(tester);
      expect(find.text('Describe the problem'), findsNothing);
      expect(find.text('Next'), findsNothing);
    });

    testWidgets('restart goes back to the first hint', (tester) async {
      await _openRecorder(tester, options: hints);
      await _tapRecord(tester);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restart'));
      await tester.pumpAndSettle();
      expect(find.text('Introduce yourself'), findsOneWidget);
      expect(find.bySemanticsLabel('Hint 1 of 3'), findsOneWidget);
    });
  });

  testWidgets('restart while recording discards the take', (tester) async {
    final host = await _openRecorder(tester);

    await _tapRecord(tester);
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();

    expect(platform.recordingsStopped, 1);
    expect(find.bySemanticsLabel('Record'), findsOneWidget);

    await _tapRecord(tester);
    await _tapStop(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(platform.recordingsStarted, 2);
    expect(host.result?.path, endsWith('/take_2.mp4'));
  });

  group('review', () {
    testWidgets('plays the take once with a scrubbable bar', (tester) async {
      await _openRecorder(tester);
      await _tapRecord(tester);
      await _tapStop(tester);

      expect(player.looping, isNot(isTrue));
      expect(player.playing, hasLength(1));
      expect(find.byType(VideoProgressIndicator), findsOneWidget);
      expect(find.text('00:03'), findsOneWidget); // the take's length
    });

    testWidgets('offers Replay when the take ends', (tester) async {
      await _openRecorder(tester);
      await _tapRecord(tester);
      await _tapStop(tester);

      player.finish(player.playing.single);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Replay'), findsOneWidget);
      expect(find.bySemanticsLabel('Pause'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Replay'));
      await tester.pumpAndSettle();
      expect(player.seeks.last, Duration.zero);
      expect(player.playing, hasLength(1));
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
    });

    testWidgets('tapping the video also replays a finished take', (
      tester,
    ) async {
      await _openRecorder(tester);
      await _tapRecord(tester);
      await _tapStop(tester);
      player.finish(player.playing.single);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(VideoPlayer));
      await tester.pumpAndSettle();
      expect(player.seeks.last, Duration.zero);
      expect(player.playing, hasLength(1));
    });
  });

  testWidgets('re-record from review records a new take', (tester) async {
    final host = await _openRecorder(tester);

    await _tapRecord(tester);
    await _tapStop(tester);
    await tester.tap(find.text('Re-record'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Record'), findsOneWidget);
    expect(find.text('Save'), findsNothing);

    await _tapRecord(tester);
    await _tapStop(tester);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(host.result?.path, endsWith('/take_2.mp4'));
  });

  testWidgets('shows elapsed time against maxDuration', (tester) async {
    await _openRecorder(
      tester,
      options: const VideoRecorderOptions(maxDuration: Duration(seconds: 60)),
    );
    expect(find.text('00:00 / 01:00'), findsOneWidget);

    await _tapRecord(tester);
    expect(find.text('00:00 / 01:00'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(find.text('Paused · 00:00 / 01:00'), findsOneWidget);

    // The finished take shows its length instead.
    await _tapStop(tester);
    expect(find.textContaining(' / '), findsNothing);
    expect(find.text('00:00'), findsOneWidget);
  });

  group('3-2-1 countdown', () {
    testWidgets('counts 3, 2, 1 then starts recording', (tester) async {
      await _openRecorder(tester);
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();

      expect(find.text('3'), findsOneWidget);
      expect(find.bySemanticsLabel('Cancel'), findsOneWidget);
      expect(find.byTooltip('Switch camera'), findsNothing);
      expect(platform.recordingsStarted, 0);

      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1'), findsOneWidget);
      expect(platform.recordingsStarted, 0);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(platform.recordingsStarted, 1);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('1'), findsNothing);
    });

    testWidgets('cancel stops the countdown', (tester) async {
      await _openRecorder(tester);
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.bySemanticsLabel('Cancel'));
      await tester.pump();
      expect(find.bySemanticsLabel('Record'), findsOneWidget);
      expect(find.text('2'), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      expect(platform.recordingsStarted, 0);
    });

    testWidgets('length follows countdownSeconds', (tester) async {
      await _openRecorder(
        tester,
        options: const VideoRecorderOptions(countdownSeconds: 5),
      );
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();
      expect(find.text('5'), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      expect(platform.recordingsStarted, 0);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(platform.recordingsStarted, 1);
    });

    testWidgets('0 starts recording immediately', (tester) async {
      await _openRecorder(
        tester,
        options: const VideoRecorderOptions(countdownSeconds: 0),
      );
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();
      expect(platform.recordingsStarted, 1);
      expect(find.bySemanticsLabel('Cancel'), findsNothing);
    });

    testWidgets('hints stay visible during the countdown', (tester) async {
      await _openRecorder(
        tester,
        options: const VideoRecorderOptions(hints: ['Introduce yourself']),
      );
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();
      expect(find.text('Introduce yourself'), findsOneWidget);
    });

    testWidgets('closing during the countdown returns null', (tester) async {
      final host = await _openRecorder(tester);
      await tester.tap(find.bySemanticsLabel('Record'));
      await tester.pump();

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(host.returned, isTrue);
      expect(host.result, isNull);
      expect(platform.recordingsStarted, 0);
    });
  });

  group('countdown ring', () {
    final ring = find.byWidgetPredicate(
      (w) => w is CustomPaint && '${w.painter.runtimeType}' == '_RingPainter',
    );

    testWidgets('surrounds the record button when there is a limit', (
      tester,
    ) async {
      await _openRecorder(
        tester,
        options: const VideoRecorderOptions(maxDuration: Duration(seconds: 60)),
      );
      expect(ring, findsOneWidget);

      await _tapRecord(tester);
      expect(ring, findsOneWidget);

      // Pausing stops the ring's animation, so the screen can settle.
      await tester.tap(find.bySemanticsLabel('Pause'));
      await tester.pumpAndSettle();
      expect(ring, findsOneWidget);
    });

    testWidgets('is not shown without a limit', (tester) async {
      await _openRecorder(tester);
      await _tapRecord(tester);
      expect(ring, findsNothing);
    });
  });

  testWidgets('counts up when there is no maxDuration', (tester) async {
    await _openRecorder(tester);
    expect(find.text('00:00'), findsOneWidget);

    await _tapRecord(tester);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.textContaining(' / '), findsNothing);
  });

  testWidgets('the timer tool turns the countdown off', (tester) async {
    await _openRecorder(tester);
    await tester.tap(find.byTooltip('Timer 3s'));
    await tester.pump();
    expect(find.byTooltip('Timer off'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Record'));
    await tester.pump();
    expect(platform.recordingsStarted, 1);
    expect(find.bySemanticsLabel('Cancel'), findsNothing);
  });

  testWidgets('the light is offered for the back camera only', (
    tester,
  ) async {
    await _openRecorder(tester);
    expect(find.byTooltip('Light off'), findsOneWidget);

    await tester.tap(find.byTooltip('Switch camera'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Light off'), findsNothing);
  });

  testWidgets('stops automatically at maxDuration', (tester) async {
    await _openRecorder(
      tester,
      options: const VideoRecorderOptions(maxDuration: Duration.zero),
    );

    await _tapRecord(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    expect(platform.recordingsStopped, 1);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('closing without saving returns null', (tester) async {
    final host = await _openRecorder(tester);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(host.returned, isTrue);
    expect(host.result, isNull);
  });

  testWidgets('shows an error when the device has no camera', (tester) async {
    CameraPlatform.instance = FakeCameraPlatform(cameras: const []);
    await _openRecorder(tester);

    expect(find.text('No camera was found on this device.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
