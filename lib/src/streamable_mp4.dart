import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

/// Moves an MP4's index (`moov`) in front of its media data, so players can
/// start a download-in-progress video without fetching the end of the file
/// first. The media is copied as-is, without re-encoding.
abstract final class StreamableMp4 {
  /// Returns a new file next to [input] with the index moved to the front,
  /// or [input] itself when it's already streamable or isn't an MP4 this can
  /// rewrite. [input] is never modified or deleted.
  static Future<XFile> ensure(XFile input) async {
    if (kIsWeb) return input;
    final inputPath = input.path;
    final outputPath = _outputPathFor(inputPath);
    try {
      // Spawning an isolate costs more than rewriting a small file.
      final rewritten = File(inputPath).lengthSync() > _isolateThreshold
          ? await Isolate.run(() => _rewrite(inputPath, outputPath))
          : _rewrite(inputPath, outputPath);
      if (rewritten) return XFile(outputPath, mimeType: 'video/mp4');
    } on FormatException {
      // Not an MP4 we understand.
    } on FileSystemException {
      // Unreadable input or unwritable output.
    }
    _deleteIfExists(outputPath);
    return input;
  }

  /// Whether [file] already has its index in front of its media data.
  static Future<bool> isStreamable(XFile file) async {
    if (kIsWeb) return false;
    try {
      final raf = File(file.path).openSync();
      try {
        return _layoutOf(_readBoxes(raf)) == _Layout.streamable;
      } finally {
        raf.closeSync();
      }
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  static const _isolateThreshold = 8 * 1024 * 1024;

  static String _outputPathFor(String input) {
    final slash = input.lastIndexOf('/');
    final dot = input.lastIndexOf('.');
    final stem = dot > slash ? input.substring(0, dot) : input;
    return '${stem}_streamable.mp4';
  }

  static void _deleteIfExists(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Nothing more to do.
    }
  }
}

class _Box {
  _Box(this.type, this.offset, this.size);

  final String type;
  final int offset;
  final int size;
}

enum _Layout { streamable, moovLast, unsupported }

/// Returns false (writing nothing) when [inputPath] needn't or can't be
/// rewritten.
bool _rewrite(String inputPath, String outputPath) {
  final input = File(inputPath).openSync();
  try {
    final boxes = _readBoxes(input);
    if (_layoutOf(boxes) != _Layout.moovLast) return false;

    final moovBox = boxes.singleWhere((b) => b.type == 'moov');
    input.setPositionSync(moovBox.offset);
    final moov = input.readSync(moovBox.size);
    if (moov.length != moovBox.size) {
      throw const FormatException('Truncated moov');
    }
    // The moov is inserted before the first mdat, so all media data moves
    // forward by exactly its size.
    if (!_shiftChunkOffsets(moov, 0, moov.length, moovBox.size)) return false;

    final firstMdat = boxes.indexWhere((b) => b.type == 'mdat');
    final order = [
      ...boxes.take(firstMdat).where((b) => b.type != 'moov'),
      moovBox,
      ...boxes.skip(firstMdat).where((b) => b.type != 'moov'),
    ];

    final output = File(outputPath).openSync(mode: FileMode.write);
    try {
      for (final box in order) {
        if (identical(box, moovBox)) {
          output.writeFromSync(moov);
        } else {
          _copy(input, output, box);
        }
      }
    } finally {
      output.closeSync();
    }
    return true;
  } finally {
    input.closeSync();
  }
}

List<_Box> _readBoxes(RandomAccessFile file) {
  final length = file.lengthSync();
  final boxes = <_Box>[];
  var offset = 0;
  while (offset < length) {
    file.setPositionSync(offset);
    final header = file.readSync(16);
    if (header.length < 8) throw const FormatException('Truncated box header');
    final data = ByteData.sublistView(header);
    var size = data.getUint32(0);
    if (size == 1) {
      if (header.length < 16) {
        throw const FormatException('Truncated box header');
      }
      size = data.getUint64(8);
    } else if (size == 0) {
      size = length - offset;
    }
    if (size < 8 || offset + size > length) {
      throw const FormatException('Bad box size');
    }
    boxes.add(_Box(String.fromCharCodes(header, 4, 8), offset, size));
    offset += size;
  }
  return boxes;
}

_Layout _layoutOf(List<_Box> boxes) {
  // Fragmented MP4s carry an index per fragment and already stream.
  if (boxes.any((b) => b.type == 'moof')) return _Layout.streamable;
  final moovs = boxes.where((b) => b.type == 'moov').toList();
  final mdats = boxes.where((b) => b.type == 'mdat').toList();
  if (moovs.length != 1 || mdats.isEmpty) return _Layout.unsupported;
  final moov = moovs.single;
  if (moov.offset < mdats.first.offset) return _Layout.streamable;
  if (moov.offset > mdats.last.offset) return _Layout.moovLast;
  return _Layout.unsupported;
}

const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};

/// Adds [by] to every chunk offset (`stco`/`co64`) inside `buf[start, end)`.
/// Returns false when the index can't be patched in place: it's compressed
/// (`cmov`), or a 32-bit offset would overflow.
bool _shiftChunkOffsets(Uint8List buf, int start, int end, int by) {
  final data = ByteData.sublistView(buf);
  var offset = start;
  while (offset + 8 <= end) {
    var size = data.getUint32(offset);
    var header = 8;
    if (size == 1) {
      size = data.getUint64(offset + 8);
      header = 16;
    } else if (size == 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) {
      throw const FormatException('Bad box size in moov');
    }
    final type = String.fromCharCodes(buf, offset + 4, offset + 8);
    final body = offset + header;
    final boxEnd = offset + size;

    switch (type) {
      case 'cmov':
        return false;
      case 'stco' || 'co64':
        final entrySize = type == 'stco' ? 4 : 8;
        final count = data.getUint32(body + 4);
        if (body + 8 + count * entrySize > boxEnd) {
          throw const FormatException('Bad chunk offset table');
        }
        for (var i = 0; i < count; i++) {
          final p = body + 8 + i * entrySize;
          if (entrySize == 4) {
            final shifted = data.getUint32(p) + by;
            if (shifted > 0xFFFFFFFF) return false;
            data.setUint32(p, shifted);
          } else {
            data.setUint64(p, data.getUint64(p) + by);
          }
        }
      default:
        if (_containers.contains(type) &&
            !_shiftChunkOffsets(buf, body, boxEnd, by)) {
          return false;
        }
    }
    offset = boxEnd;
  }
  return true;
}

void _copy(RandomAccessFile from, RandomAccessFile to, _Box box) {
  const chunk = 1024 * 1024;
  from.setPositionSync(box.offset);
  var remaining = box.size;
  while (remaining > 0) {
    final bytes = from.readSync(remaining < chunk ? remaining : chunk);
    if (bytes.isEmpty) throw const FormatException('Unexpected end of file');
    to.writeFromSync(bytes);
    remaining -= bytes.length;
  }
}
