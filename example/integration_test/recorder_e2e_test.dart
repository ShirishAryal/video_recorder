import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder/video_recorder.dart';

/// Needs a camera, with camera and microphone permission already granted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// pumpAndSettle would never return: the camera preview keeps redrawing.
  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder');
  }

  Future<XFile?> recordAndSave(
    WidgetTester tester, {
    required bool convertToHevc,
  }) async {
    XFile? saved;
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              saved = await VideoRecorder.record(
                context,
                options: VideoRecorderOptions(
                  convertToHevc: convertToHevc,
                  countdownSeconds: 1,
                ),
              );
              returned = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));

    const noCamera = 'No camera was found on this device.';
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate(
        (w) => w is Text && (w.data == 'Record' || w.data == noCamera),
      ),
    );
    if (find.text(noCamera).evaluate().isNotEmpty) {
      markTestSkipped('No camera on this device (e.g. the iOS simulator).');
      return null;
    }

    await tester.tap(find.bySemanticsLabel('Record'));
    await pumpUntilFound(tester, find.bySemanticsLabel('Pause'));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('Done'));

    await pumpUntilFound(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (!returned && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(saved, isNotNull);
    return saved;
  }

  testWidgets('record, then save as HEVC', (tester) async {
    final file = await recordAndSave(tester, convertToHevc: true);
    if (file == null) return;
    expect(file.path, endsWith('_hevc.mp4'));
    // ignore: avoid_print
    print('E2E_RESULT path=${file.path} bytes=${File(file.path).lengthSync()}');
    expect(await StreamableMp4.isStreamable(file), isTrue);

    // A second conversion reports "already HEVC", using the platform's own
    // codec detection.
    final check = await HevcConverter.convert(file, bitrate: 1500000);
    expect(check.status, HevcConversionStatus.alreadyHevc);

    const copyTo = String.fromEnvironment('HEVC_COPY_TO');
    if (copyTo.isNotEmpty) await File(file.path).copy(copyTo);
  });

  testWidgets('record, then save without conversion', (tester) async {
    final file = await recordAndSave(tester, convertToHevc: false);
    if (file == null) return;
    // ignore: avoid_print
    print('E2E_PLAIN path=${file.path}');
    expect(await StreamableMp4.isStreamable(file), isTrue);
  });
}
