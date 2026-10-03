import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_recorder/src/messages.g.dart';

/// By default `convert` writes a 400-byte output file and reports success.
class FakeHevcHostApi extends HevcConverterHostApi {
  FakeHevcHostApi({this.reply});

  Future<ConversionReply> Function(ConversionRequest request)? reply;

  final List<ConversionRequest> requests = [];
  final List<int> cancelled = [];

  final Completer<void> cancelRequested = Completer<void>();

  @override
  Future<ConversionReply> convert(ConversionRequest request) async {
    requests.add(request);
    final reply = this.reply;
    if (reply != null) return reply(request);
    File(request.outputPath).writeAsBytesSync(List.filled(400, 1));
    return ConversionReply(status: NativeConversionStatus.converted);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    if (!cancelRequested.isCompleted) cancelRequested.complete();
  }
}

/// Goes through the real Pigeon channel, as the native side would.
Future<void> sendProgress(
  TestDefaultBinaryMessenger messenger,
  int id,
  double progress,
) {
  final done = Completer<void>();
  messenger.handlePlatformMessage(
    'dev.flutter.pigeon.video_recorder.HevcConverterFlutterApi.onProgress',
    const StandardMessageCodec().encodeMessage(<Object?>[id, progress]),
    (_) => done.complete(),
  );
  return done.future;
}
