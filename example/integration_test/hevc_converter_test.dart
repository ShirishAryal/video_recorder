import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late XFile sample;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hevc_test');
    final bytes = await rootBundle.load(
      'integration_test/assets/sample_h264.mp4',
    );
    final file = File('${dir.path}/sample.mp4');
    await file.writeAsBytes(bytes.buffer.asUint8List());
    sample = XFile(file.path);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('converts H.264 to a smaller HEVC file', (tester) async {
    final progress = <double>[];
    final result = await HevcConverter.convert(
      sample,
      bitrate: 1500000,
      onProgress: progress.add,
    );

    // ignore: avoid_print
    print(
      'HEVC_RESULT status=${result.status} reason=${result.reason} '
      'input=${File(sample.path).lengthSync()} '
      'output=${File(result.file.path).lengthSync()} path=${result.file.path}',
    );

    expect(
      result.status,
      HevcConversionStatus.converted,
      reason: result.reason,
    );
    expect(result.file.path, endsWith('sample_hevc.mp4'));
    expect(
      File(result.file.path).lengthSync(),
      lessThan(File(sample.path).lengthSync()),
    );
    expect(File(sample.path).existsSync(), isTrue, reason: 'original kept');
    expect(await StreamableMp4.isStreamable(result.file), isTrue);
    expect(progress, isNotEmpty);
    expect(progress.last, greaterThan(0.5));

    // On a simulator, `--dart-define=HEVC_COPY_TO=/some/host/path.mp4`
    // copies the result out so it can be inspected (e.g. with ffprobe).
    const copyTo = String.fromEnvironment('HEVC_COPY_TO');
    if (copyTo.isNotEmpty) await File(result.file.path).copy(copyTo);
  });

  testWidgets('leaves an HEVC file alone', (tester) async {
    final first = await HevcConverter.convert(sample, bitrate: 1500000);
    expect(first.converted, isTrue, reason: first.reason);

    final second = await HevcConverter.convert(first.file, bitrate: 1500000);
    expect(second.status, HevcConversionStatus.alreadyHevc);
    expect(second.file.path, first.file.path);
  });

  testWidgets('cancelling keeps the original and removes the output', (
    tester,
  ) async {
    final result = await HevcConverter.convert(
      sample,
      bitrate: 1500000,
      cancel: Future<void>.delayed(const Duration(milliseconds: 50)),
    );

    expect(result.status, HevcConversionStatus.cancelled);
    expect(result.file.path, sample.path);
    expect(File('${dir.path}/sample_hevc.mp4').existsSync(), isFalse);
  });
}
