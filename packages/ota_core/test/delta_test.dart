import 'dart:math';
import 'dart:typed_data';

import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

Uint8List _randomBytes(Random random, int length) =>
    Uint8List.fromList(List<int>.generate(length, (_) => random.nextInt(256)));

void main() {
  group('computeDelta', () {
    test('identical images produce one big COPY', () {
      final random = Random(7);
      final base = _randomBytes(random, 4096);
      final result = computeDelta(base, Uint8List.fromList(base));
      expect(result.literalBytes, 0);
      expect(result.copyBytes, 4096);
      expect(result.ops, isNotEmpty);
      expect(result.ops.every((op) => op is CopyOp), isTrue);
    });

    test('completely different images produce all literal', () {
      final random = Random(11);
      final base = _randomBytes(random, 8192);
      final target = _randomBytes(random, 8192);
      final result = computeDelta(base, target);
      expect(result.copyBytes, 0);
      expect(result.literalBytes, 8192);
    });

    test('random round trip: ops reassemble the target exactly', () {
      final random = Random(2026);
      for (var trial = 0; trial < 30; trial++) {
        final base = _randomBytes(random, 20000);
        final target = Uint8List.fromList(base);
        // Mangle: overwrite, insert, delete, and append random regions.
        final editCount = 1 + random.nextInt(4);
        final builder = BytesBuilder();
        var cursor = 0;
        for (var e = 0; e < editCount; e++) {
          final cut = cursor + random.nextInt(target.length - cursor + 1);
          builder.add(target.sublist(cursor, cut));
          final kind = random.nextInt(3);
          if (kind == 0) {
            // overwrite some bytes
            final end = (cut + random.nextInt(200) + 1).clamp(0, target.length);
            builder.add(_randomBytes(random, end - cut));
            cursor = end;
          } else if (kind == 1) {
            // insert bytes
            builder.add(_randomBytes(random, random.nextInt(300) + 1));
            // cursor unchanged
          } else {
            // delete bytes
            cursor = (cut + random.nextInt(150) + 1).clamp(0, target.length);
          }
        }
        builder.add(target.sublist(cursor));
        final finalImage = builder.toBytes();

        final delta = computeDelta(base, finalImage);
        final reassembled =
            applyDelta(base, delta.ops, expectedLength: finalImage.length);
        expect(reassembled, finalImage, reason: 'trial $trial');
      }
    });

    test('shifted content still matches (full-position index)', () {
      final random = Random(99);
      final base = _randomBytes(random, 30000);
      // Insert 137 random bytes at the front: every base block shifts.
      final target =
          Uint8List.fromList([..._randomBytes(random, 137), ...base]);
      final delta = computeDelta(base, target);
      expect(delta.copyBytes, greaterThan(25000),
          reason: 'a prefixed file must still delta against its base');
      final reassembled =
          applyDelta(base, delta.ops, expectedLength: target.length);
      expect(reassembled, target);
    });

    test('literals are split to u16 wire chunks', () {
      final random = Random(5);
      final target = _randomBytes(random, 100000);
      final result =
          computeDelta(Uint8List(0), target); // empty base forces all literal
      expect(result.ops, isNotEmpty);
      for (final op in result.ops) {
        expect(op, isA<LiteralOp>());
        expect((op as LiteralOp).data.length, lessThanOrEqualTo(0xFFFF));
      }
    });

    test('empty target produces empty ops', () {
      final result = computeDelta(_randomBytes(Random(1), 1000), Uint8List(0));
      expect(result.ops, isEmpty);
      expect(result.literalBytes, 0);
      expect(result.copyBytes, 0);
    });

    test('adjacent-build shape: localized edits keep the delta small', () {
      final random = Random(1234);
      final base = _randomBytes(random, 200000);
      // Simulate an adjacent build: reuse the base everywhere except a few
      // clusters of bytes that changed (the codegen case — unchanged
      // functions produce identical runs; changed ones differ locally).
      final target = Uint8List.fromList(base);
      for (var cluster = 0; cluster < 100; cluster++) {
        final offset = random.nextInt(target.length - 32);
        for (var i = 0; i < 24; i++) {
          target[offset + i] = random.nextInt(256);
        }
      }
      final delta = computeDelta(base, target);
      expect(delta.literalBytes, lessThan(target.length ~/ 4),
          reason: 'localized edits must delta against the base');
      final reassembled =
          applyDelta(base, delta.ops, expectedLength: target.length);
      expect(reassembled, target);
    });
  });

  test('compressed literal ops describe themselves and refuse local apply', () {
    final op = CompressedLiteralOp(Uint8List.fromList([1, 2, 3]), 1024);
    expect(op.toString(), contains('1024'));
    expect(
      () => applyDelta(Uint8List(0), [op], expectedLength: 1024),
      throwsUnsupportedError,
    );
  });
}
