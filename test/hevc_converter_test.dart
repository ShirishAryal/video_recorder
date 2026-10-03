import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_recorder/src/messages.g.dart';
import 'package:video_recorder/video_recorder.dart';

import 'fake_hevc_host_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory dir;
  late XFile input;
  late FakeHevcHostApi native;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hevc_converter_test');
    input = XFile(
      (File(
        '${dir.path}/take.mp4',
      )..writeAsBytesSync(List.filled(1000, 0))).path,
    );
    native = FakeHevcHostApi();
    HevcConverter.hostApi = native;
  });

  tearDown(() {
    HevcConverter.hostApi = HevcConverterHostApi();
    dir.deleteSync(recursive: true);
  });

  test('returns the smaller HEVC file and keeps the original', () async {
    final result = await HevcConverter.convert(input, bitrate: 1500000);

    expect(result.status, HevcConversionStatus.converted);
    expect(result.converted, isTrue);
    expect(result.file.path, '${dir.path}/take_hevc.mp4');
    expect(File(result.file.path).lengthSync(), 400);
    expect(File(input.path).existsSync(), isTrue);

    final request = native.requests.single;
    expect(request.inputPath, input.path);
    expect(request.outputPath, '${dir.path}/take_hevc.mp4');
    expect(request.bitrate, 1500000);
  });

  test('keeps the original when the HEVC file is not smaller', () async {
    native.reply = (request) async {
      File(request.outputPath).writeAsBytesSync(List.filled(1000, 1));
      return ConversionReply(status: NativeConversionStatus.converted);
    };

    final result = await HevcConverter.convert(input, bitrate: 1500000);

    expect(result.status, HevcConversionStatus.notSmaller);
    expect(result.file.path, input.path);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(File('${dir.path}/take_hevc.mp4').existsSync(), isFalse);
  });

  test('maps native outcomes that keep the original', () async {
    for (final (native_, expected) in [
      (NativeConversionStatus.alreadyHevc, HevcConversionStatus.alreadyHevc),
      (NativeConversionStatus.unsupported, HevcConversionStatus.unsupported),
      (NativeConversionStatus.cancelled, HevcConversionStatus.cancelled),
    ]) {
      native.reply = (_) async =>
          ConversionReply(status: native_, reason: 'because');
      final result = await HevcConverter.convert(input, bitrate: 1);
      expect(result.status, expected, reason: '$native_');
      expect(result.file.path, input.path);
      expect(result.reason, 'because');
    }
  });

  test('a native error keeps the original', () async {
    native.reply = (_) async =>
        throw PlatformException(code: 'conversion_failed', message: 'boom');

    final result = await HevcConverter.convert(input, bitrate: 1500000);

    expect(result.status, HevcConversionStatus.failed);
    expect(result.reason, 'boom');
    expect(result.file.path, input.path);
  });

  test('is unsupported when the native side is missing', () async {
    // The real generated API, with nothing listening on its channel.
    HevcConverter.hostApi = HevcConverterHostApi();

    final result = await HevcConverter.convert(input, bitrate: 1500000);

    expect(result.status, HevcConversionStatus.unsupported);
    expect(result.file.path, input.path);
  });

  test('passes native progress to the right caller', () async {
    final progress = <double>[];
    native.reply = (request) async {
      await sendProgress(messenger, request.id, 0.25);
      await sendProgress(messenger, request.id + 1000, 0.9);
      await sendProgress(messenger, request.id, 1);
      File(request.outputPath).writeAsBytesSync(List.filled(400, 1));
      return ConversionReply(status: NativeConversionStatus.converted);
    };

    await HevcConverter.convert(
      input,
      bitrate: 1500000,
      onProgress: progress.add,
    );

    expect(progress, [0.25, 1.0]);
  });

  test('completing cancel asks the native side to cancel', () async {
    final cancel = Completer<void>();
    native.reply = (_) async {
      await native.cancelRequested.future;
      return ConversionReply(status: NativeConversionStatus.cancelled);
    };

    final pending = HevcConverter.convert(
      input,
      bitrate: 1500000,
      cancel: cancel.future,
    );
    cancel.complete();
    final result = await pending;

    expect(result.status, HevcConversionStatus.cancelled);
    expect(native.cancelled, [native.requests.single.id]);
  });
}
