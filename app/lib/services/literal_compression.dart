import 'dart:io';
import 'dart:typed_data';

import 'package:ota_core/ota_core.dart';

/// Deflate runs of new bytes with the highest compression level. The node only
/// needs a decompressor (ROM miniz on ESP32), so this side does the expensive
/// work. GZipCodec wraps raw DEFLATE in a 10-byte header and 8-byte trailer;
/// the node consumes the raw stream only.
const _gzipHeader = 10;
const _gzipTrailer = 8;

final constGzip = GZipCodec(level: 9);

/// OP_LITERAL_Z carries comp_len as a u16. A single stream longer than this
/// wraps on the wire and the node rejects it, so runs are split into streams
/// that each fit the field.
const maxCompressedStream = 65535;

Uint8List rawDeflate(List<int> bytes) {
  if (bytes.isEmpty) return Uint8List(0);
  final gz = constGzip.encode(bytes);
  assert(gz.length > _gzipHeader + _gzipTrailer);
  assert(gz[0] == 0x1F && gz[1] == 0x8B && gz[3] == 0);
  return Uint8List.fromList(gz.sublist(_gzipHeader, gz.length - _gzipTrailer));
}

/// Replace consecutive [LiteralOp]s with one [CompressedLiteralOp] when that
/// actually saves bytes. COPY ops are left alone — they already reuse bytes
/// from the node's running image and compressing them would only add cost.
List<DeltaOp> compressLiteralRuns(List<DeltaOp> ops, {int minRun = 2048}) {
  final out = <DeltaOp>[];
  var run = <Uint8List>[];
  var runLength = 0;

  void flushRun() {
    if (run.isEmpty) return;
    final original = run;
    run = <Uint8List>[];
    final total = runLength;
    runLength = 0;
    if (total < minRun) {
      out.addAll(original.map((data) => LiteralOp(data)));
      return;
    }
    final builder = BytesBuilder(copy: false);
    for (final chunk in original) {
      builder.add(chunk);
    }
    final flat = builder.takeBytes();
    // Cap each input piece at the wire's u16 comp_len. A piece that fits also
    // compresses to at most that many bytes (we only compress when it shrinks),
    // so every emitted stream is representable.
    var at = 0;
    while (at < flat.length) {
      final end = at + maxCompressedStream > flat.length
          ? flat.length
          : at + maxCompressedStream;
      final piece = Uint8List.sublistView(flat, at, end);
      final compressed = rawDeflate(piece);
      // The wire needs a 7-byte header per stream plus framing; don't pay for
      // a compressed stream that is not clearly smaller.
      if (compressed.length + 16 < piece.length) {
        out.add(CompressedLiteralOp(compressed, piece.length));
      } else {
        out.add(LiteralOp(piece));
      }
      at = end;
    }
  }

  for (final op in ops) {
    if (op is LiteralOp) {
      run.add(op.data);
      runLength += op.data.length;
    } else {
      flushRun();
      out.add(op);
    }
  }
  flushRun();
  return out;
}
