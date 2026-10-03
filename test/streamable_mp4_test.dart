import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_recorder/video_recorder.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('streamable_mp4'));
  tearDown(() => dir.deleteSync(recursive: true));

  XFile copyFixture(String name) =>
      XFile(File('test/fixtures/$name').copySync('${dir.path}/$name').path);

  XFile write(String name, List<int> bytes) =>
      XFile((File('${dir.path}/$name')..writeAsBytesSync(bytes)).path);

  test('moves the index of a real recording to the front', () async {
    final input = copyFixture('moov_last.mp4');
    final before = File(input.path).readAsBytesSync();

    final output = await StreamableMp4.ensure(input);

    expect(output.path, '${dir.path}/moov_last_streamable.mp4');
    expect(topLevelTypes(output.path), ['ftyp', 'free', 'moov', 'mdat']);
    expect(File(output.path).lengthSync(), before.length);
    expect(File(input.path).readAsBytesSync(), before, reason: 'untouched');
    expect(await StreamableMp4.isStreamable(output), isTrue);

    // Every chunk offset must still point at the same media bytes.
    final oldOffsets = chunkOffsets(before);
    final after = File(output.path).readAsBytesSync();
    final newOffsets = chunkOffsets(after);
    expect(newOffsets, hasLength(oldOffsets.length));
    expect(oldOffsets, isNotEmpty);
    for (var i = 0; i < oldOffsets.length; i++) {
      expect(
        after.sublist(newOffsets[i], newOffsets[i] + 32),
        before.sublist(oldOffsets[i], oldOffsets[i] + 32),
        reason: 'chunk $i',
      );
    }
  });

  test('leaves an already streamable file alone', () async {
    final input = copyFixture('moov_first.mp4');

    expect(await StreamableMp4.isStreamable(input), isTrue);
    expect((await StreamableMp4.ensure(input)).path, input.path);
    expect(File('${dir.path}/moov_first_streamable.mp4').existsSync(), isFalse);
  });

  test('leaves files that are not MP4s alone', () async {
    final input = write('zeros.mp4', List.filled(1000, 0));

    expect(await StreamableMp4.isStreamable(input), isFalse);
    expect((await StreamableMp4.ensure(input)).path, input.path);
    expect(File('${dir.path}/zeros_streamable.mp4').existsSync(), isFalse);
  });

  test('shifts 64-bit chunk offsets', () async {
    final payload = 'HELLO WORLD'.codeUnits;
    final ftyp = _ftyp();
    final mdatOffset = ftyp.length + 8;
    final input = write('co64.mp4', [
      ...ftyp,
      ..._box('mdat', payload),
      ..._moov(_fullBox('co64', [..._u32(1), ..._u64(mdatOffset)])),
    ]);

    final output = await StreamableMp4.ensure(input);

    final bytes = File(output.path).readAsBytesSync();
    expect(topLevelTypes(output.path), ['ftyp', 'moov', 'mdat']);
    final offset = chunkOffsets(bytes).single;
    expect(bytes.sublist(offset, offset + payload.length), payload);
  });

  test('gives up when a 32-bit offset would overflow', () async {
    final input = write('overflow.mp4', [
      ..._ftyp(),
      ..._box('mdat', [1, 2, 3]),
      ..._moov(_fullBox('stco', [..._u32(1), ..._u32(0xFFFFFFF0)])),
    ]);

    expect((await StreamableMp4.ensure(input)).path, input.path);
    expect(File('${dir.path}/overflow_streamable.mp4').existsSync(), isFalse);
  });

  test('gives up on a compressed index', () async {
    final input = write('cmov.mp4', [
      ..._ftyp(),
      ..._box('mdat', [1, 2, 3]),
      ..._box('moov', _box('cmov', [0, 0, 0, 0])),
    ]);

    expect((await StreamableMp4.ensure(input)).path, input.path);
  });

  test('treats fragmented MP4s as streamable', () async {
    final input = write('fragmented.mp4', [
      ..._ftyp(),
      ..._moov(_fullBox('stco', _u32(0))),
      ..._box('moof', []),
      ..._box('mdat', [1, 2, 3]),
    ]);

    expect(await StreamableMp4.isStreamable(input), isTrue);
    expect((await StreamableMp4.ensure(input)).path, input.path);
  });

  test('rewrites large files on a background isolate', () async {
    final payload = Uint8List(9 * 1024 * 1024)..[0] = 42;
    final ftyp = _ftyp();
    final mdatOffset = ftyp.length + 8;
    final input = write('large.mp4', [
      ...ftyp,
      ..._box('mdat', payload),
      ..._moov(_fullBox('stco', [..._u32(1), ..._u32(mdatOffset)])),
    ]);

    final output = await StreamableMp4.ensure(input);

    final bytes = File(output.path).readAsBytesSync();
    expect(topLevelTypes(output.path), ['ftyp', 'moov', 'mdat']);
    expect(bytes[chunkOffsets(bytes).single], 42);
  });
}

List<String> topLevelTypes(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  final types = <String>[];
  var offset = 0;
  while (offset < bytes.length) {
    var size = data.getUint32(offset);
    if (size == 1) size = data.getUint64(offset + 8);
    types.add(String.fromCharCodes(bytes, offset + 4, offset + 8));
    offset += size;
  }
  return types;
}

/// All `stco`/`co64` entries in the file, in order.
List<int> chunkOffsets(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final offsets = <int>[];
  void walk(int start, int end) {
    var offset = start;
    while (offset + 8 <= end) {
      var size = data.getUint32(offset);
      var header = 8;
      if (size == 1) {
        size = data.getUint64(offset + 8);
        header = 16;
      }
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final body = offset + header;
      if (type == 'stco' || type == 'co64') {
        final count = data.getUint32(body + 4);
        for (var i = 0; i < count; i++) {
          offsets.add(
            type == 'stco'
                ? data.getUint32(body + 8 + i * 4)
                : data.getUint64(body + 8 + i * 8),
          );
        }
      } else if (const {
        'moov',
        'trak',
        'mdia',
        'minf',
        'stbl',
      }.contains(type)) {
        walk(body, offset + size);
      }
      offset += size;
    }
  }

  walk(0, bytes.length);
  return offsets;
}

List<int> _u32(int v) => [
  (v >> 24) & 255,
  (v >> 16) & 255,
  (v >> 8) & 255,
  v & 255,
];
List<int> _u64(int v) => [..._u32(v >> 32), ..._u32(v & 0xFFFFFFFF)];

List<int> _box(String type, List<int> body) => [
  ..._u32(8 + body.length),
  ...type.codeUnits,
  ...body,
];

List<int> _fullBox(String type, List<int> body) =>
    _box(type, [0, 0, 0, 0, ...body]);

List<int> _ftyp() => _box('ftyp', [...'isom'.codeUnits, ..._u32(0)]);

List<int> _moov(List<int> chunkOffsetBox) => _box(
  'moov',
  _box('trak', _box('mdia', _box('minf', _box('stbl', chunkOffsetBox)))),
);
