import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

final testContact = Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  name: 'tower-1',
  advType: advTypeRepeater,
  outPathLen: -1,
);

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

Uint8List _image(int length, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(
        length, (i) => (((i + seed * 113) * 2654435761) >> 16) & 0xFF));

int _rolling(Uint8List d, int at, int len) {
  var h = 0;
  for (var i = 0; i < len; i++) {
    h = ((h * 0x00000100000001B3) + d[at + i]) & 0xFFFFFFFFFFFFFFFF;
  }
  return h;
}

/// A node that answers OP_BLOCK_HASH and batched OP_BLOCK_FIND from one
/// in-memory running image.
class Oracle {
  Oracle(this.running) {
    link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      queries++;
      final frame = Uint8List.fromList(reqData.sublist(2));
      final reply = frame[2] == otaOpBlockFind ? _find(frame) : _meta();
      final padded = Uint8List.fromList([
        ...reply,
        ...List<int>.filled((16 - reply.length % 16) % 16, 0),
      ]);
      link.simulatePush(Uint8List.fromList([
        pushCodeBinaryResponse,
        0,
        ..._le32(tag),
        ...padded,
      ]));
    };
  }

  final Uint8List running;
  late final FakeDeviceLink link;
  int queries = 0;

  Uint8List _meta() {
    final body = <int>[..._le32(running.length), 0, 0];
    body.addAll(List<int>.filled(blockHashMaxSegments * 8, 0));
    body.addAll(running.isEmpty
        ? List<int>.filled(32, 0)
        : sha256.convert(running).bytes);
    return buildOp(otaOpBlockHashReport, body: body);
  }

  Uint8List _find(Uint8List frame) {
    final length =
        frame[3] | (frame[4] << 8) | (frame[5] << 16) | (frame[6] << 24);
    final start =
        frame[7] | (frame[8] << 8) | (frame[9] << 16) | (frame[10] << 24);
    final end =
        frame[11] | (frame[12] << 8) | (frame[13] << 16) | (frame[14] << 24);
    final count = frame[15];
    final wants = <int>[];
    for (var i = 0; i < count; i++) {
      final at = 16 + i * 8;
      wants.add(frame[at] |
          (frame[at + 1] << 8) |
          (frame[at + 2] << 16) |
          (frame[at + 3] << 24) |
          (frame[at + 4] << 32) |
          (frame[at + 5] << 40) |
          (frame[at + 6] << 48) |
          (frame[at + 7] << 56));
    }
    final hits = List.generate(count, (_) => <int>[]);
    for (var off = start; off + length <= end; off += 4) {
      final h = _rolling(running, off, length);
      for (var i = 0; i < count; i++) {
        if (h == wants[i] && hits[i].length < blockFindHitsPer)
          hits[i].add(off);
      }
    }
    final body = <int>[count];
    for (final list in hits) {
      body.add(list.length);
      for (final hit in list) {
        body.addAll(_le32(hit));
      }
    }
    return buildOp(otaOpBlockFindReport, body: body);
  }

  Future<RemoteDiffResult> diff(Uint8List image, {int blockSize = 256}) =>
      computeRemoteDiff(
        client: BlockHashClient(
            link: link,
            contact: testContact,
            timeout: const Duration(seconds: 1)),
        image: image,
        blockSize: blockSize,
      );
}

void main() {
  test('an identical image is detected with one query and no ops', () async {
    final image = _image(2048, 1);
    final oracle = Oracle(image);
    final result = await oracle.diff(image);
    expect(result.upToDate, isTrue);
    expect(result.ops, isEmpty);
    expect(result.queries, 1);
  });

  test('a node that cannot hash its image gets a full image', () async {
    final image = _image(2048, 1);
    final oracle = Oracle(Uint8List(0));
    final result = await oracle.diff(image);
    expect(result.upToDate, isFalse);
    expect(result.literalBytes, image.length);
    expect(result.ops.single, isA<LiteralOp>());
  });

  test('blocks are copied by content even after a shift', () async {
    final image = _image(4096, 1);
    final running = Uint8List.fromList([
      ...List<int>.filled(400, 0xEE),
      ...image,
    ]);
    final oracle = Oracle(running);
    final result = await oracle.diff(image, blockSize: 256);
    expect(result.upToDate, isFalse);
    expect(result.copyBytes, image.length);
    expect(result.literalBytes, 0);
    expect(
      result.ops.where((op) => op is CopyOp && op.baseOffset == 400).length,
      greaterThan(0),
    );
    expect(
        applyDelta(running, result.ops, expectedLength: image.length), image);
  });

  test('a changed region becomes literals while the rest is reused', () async {
    final image = _image(4096, 1);
    final running = Uint8List.fromList(image);
    for (var i = 1024; i < 2048; i++) {
      running[i] ^= 0xFF;
    }
    final oracle = Oracle(running);
    final result = await oracle.diff(image, blockSize: 256);
    expect(result.copyBytes, greaterThan(image.length ~/ 2));
    expect(result.literalBytes, greaterThan(0));
    expect(
        applyDelta(running, result.ops, expectedLength: image.length), image);
    // Twelve fingerprints per exchange, not one.
    expect(result.queries, lessThan(30));
  });

  test('a multi-byte shift is recovered by content, not offset', () async {
    final image = _image(4096, 1);
    final running = Uint8List.fromList([
      ...image.sublist(0, 1000),
      0xAA,
      0xBB,
      0xCC,
      0xDD,
      ...image.sublist(1000),
    ]);
    final oracle = Oracle(running);
    final result = await oracle.diff(image, blockSize: 256);
    final shifted =
        result.ops.where((op) => op is CopyOp && op.baseOffset > 1000).length;
    expect(shifted, greaterThan(0));
    expect(
        applyDelta(running, result.ops, expectedLength: image.length), image);
  });

  test('a trailing partial block never loses bytes', () async {
    final full = _image(1030, 3);
    final running = Uint8List.fromList(full);
    running[500] ^= 0xFF;
    final oracle = Oracle(running);
    final result = await oracle.diff(full, blockSize: 256);
    expect(applyDelta(running, result.ops, expectedLength: full.length), full);
    expect(result.copyBytes + result.literalBytes, full.length);
  });

  test('cancellation leaves the node untouched', () async {
    final image = _image(2048, 1);
    final oracle = Oracle(image);
    expect(
      computeRemoteDiff(
        client: BlockHashClient(
            link: oracle.link,
            contact: testContact,
            timeout: const Duration(seconds: 1)),
        image: image,
        shouldCancel: () => true,
      ),
      throwsA(isA<RemoteDiffException>()),
    );
  });

  test('ESP segment parsing mirrors the node header layout', () {
    final image = Uint8List(24 + 8 + 400 + 1);
    image[0] = 0xE9;
    image[1] = 1;
    image[28] = 400 & 0xFF;
    image[29] = (400 >> 8) & 0xFF;
    expect(parseEspSegments(image).single.offset, 32);
    expect(parseEspSegments(image).single.length, 400);
  });
}
