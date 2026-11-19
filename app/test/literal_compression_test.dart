import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ota_core/ota_core.dart';

import 'package:meshcore_ota/services/literal_compression.dart';

void main() {
  test('a compressible literal run becomes one compressed op', () {
    final data = Uint8List.fromList(List<int>.filled(8192, 0x5A));
    final ops = compressLiteralRuns([LiteralOp(data)]);
    expect(ops, hasLength(1));
    expect(ops.single, isA<CompressedLiteralOp>());
    final comp = ops.single as CompressedLiteralOp;
    expect(comp.originalLength, 8192);
    expect(comp.compressed.length, lessThan(100));
  });

  test('incompressible bytes stay literal and copies are untouched', () {
    var x = 0x12345678;
    final data = Uint8List.fromList(List<int>.generate(8192, (_) {
      x ^= (x << 13) & 0xFFFFFFFF;
      x ^= x >> 17;
      x ^= (x << 5) & 0xFFFFFFFF;
      return x & 0xFF;
    }));
    final ops = compressLiteralRuns([
      const CopyOp(32, 128),
      LiteralOp(data),
    ]);
    expect(ops[0], isA<CopyOp>());
    expect(ops[1], isA<LiteralOp>());
    expect((ops[1] as LiteralOp).data, data);
  });

  test('a short run is not compressed', () {
    final ops = compressLiteralRuns([LiteralOp(Uint8List(64))]);
    expect(ops.single, isA<LiteralOp>());
  });

  test('the raw deflate payload has no gzip wrapper', () {
    final raw = rawDeflate(List<int>.filled(1024, 7));
    expect(raw[0], isNot(0x1F));
    expect(raw.length, lessThan(1024));
  });
}
