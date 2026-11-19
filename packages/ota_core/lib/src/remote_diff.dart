import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'block_hash.dart';
import 'delta.dart';

/// A running total for the long "compare" phase. The tree is not adaptive any
/// more, so a simple fraction is honest.
class RemoteDiffProgress {
  const RemoteDiffProgress({
    required this.queries,
    required this.rangesHashed,
    required this.bytesReused,
    required this.bytesToSend,
    required this.shiftProbeBatches,
  });

  final int queries;
  final int rangesHashed;
  final int bytesReused;
  final int bytesToSend;
  final int shiftProbeBatches;

  double get fraction {
    final total = bytesReused + bytesToSend;
    return total == 0 ? 0 : bytesReused / total;
  }
}

/// The op stream derived from hashes of the node's running image. No local
/// copy of the old firmware is needed: the node is the oracle for its bytes.
class RemoteDiffResult {
  const RemoteDiffResult({
    required this.ops,
    required this.literalBytes,
    required this.copyBytes,
    required this.node,
    required this.queries,
    required this.rangesHashed,
    required this.shiftProbeBatches,
    required this.upToDate,
  });

  final List<DeltaOp> ops;
  final int literalBytes;
  final int copyBytes;
  final RunningImageInfo node;

  /// REQ/RESPONSE exchanges spent on the diff.
  final int queries;
  final int rangesHashed;
  final int shiftProbeBatches;
  final bool upToDate;
}

class RemoteDiffException implements Exception {
  const RemoteDiffException(this.message);

  final String message;

  @override
  String toString() => 'RemoteDiffException: $message';
}

/// Parse the payload segments of an ESP app image. Mirrors
/// `runningImageLength()` in the firmware: a 24-byte header, then [count]
/// 8-byte segment headers followed by their 4-byte-aligned payloads.
List<ImageSegment> parseEspSegments(Uint8List image) {
  if (image.length < 24 || image[0] != 0xE9) return const [];
  final count = image[1];
  if (count < 1 || count > 16) return const [];
  final segments = <ImageSegment>[];
  var off = 24;
  for (var i = 0; i < count; i++) {
    if (off + 8 > image.length) break;
    final len = image[off + 4] |
        (image[off + 5] << 8) |
        (image[off + 6] << 16) |
        (image[off + 7] << 24);
    final payload = off + 8;
    if (len < 0 || payload + len > image.length) break;
    segments.add(ImageSegment(payload, len));
    off = (payload + len + 3) & ~3;
    if (off >= image.length) break;
  }
  return segments;
}

const int _rollingPrime = 0x00000100000001B3;
const int _mask64 = 0xFFFFFFFFFFFFFFFF;

/// The polynomial hash shared with the firmware's OP_BLOCK_FIND scanner.
int rolling64(Uint8List data, int offset, int length) {
  var h = 0;
  for (var i = 0; i < length; i++) {
    h = ((h * _rollingPrime) + data[offset + i]) & _mask64;
  }
  return h;
}

bool _sameHash(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Compute the op stream by asking the node to locate each block of the new
/// image inside its running image. Finding a block is a single REQ/RESPONSE
/// exchange and yields a COPY from the exact offset — including after an edit
/// has shifted every following byte, which same-offset comparison cannot do.
Future<RemoteDiffResult> computeRemoteDiff({
  required BlockHashClient client,
  required Uint8List image,
  // 1 KB blocks: four times fewer find queries than 256 B (the node-side
  // scan, not airtime, dominates Compare) while keeping reuse within ~4% of
  // the finest granularity on real r2->r3->r4 firmware images.
  int blockSize = 1024,
  int searchWindow = 32768,
  void Function(RemoteDiffProgress)? onProgress,
  bool Function()? shouldCancel,
}) async {
  assert(
      blockSize >= 4 && blockSize % 4 == 0 && blockSize <= blockHashMaxRange);
  final cancel = shouldCancel ?? (() => false);
  var queries = 0;
  var reused = 0;
  var toSend = 0;
  void progress() => onProgress?.call(RemoteDiffProgress(
        queries: queries,
        rangesHashed: queries,
        bytesReused: reused,
        bytesToSend: toSend,
        shiftProbeBatches: 0,
      ));

  final node = await client.metadata();
  queries++;
  if (cancel()) throw const RemoteDiffException('cancelled');
  if (node.canHash &&
      node.size == image.length &&
      _sameHash(node.sha256, sha256.convert(image).bytes)) {
    progress();
    return RemoteDiffResult(
      ops: const [],
      literalBytes: 0,
      copyBytes: 0,
      node: node,
      queries: queries,
      rangesHashed: 0,
      shiftProbeBatches: 0,
      upToDate: true,
    );
  }
  if (!node.canHash) {
    progress();
    return RemoteDiffResult(
      ops: [LiteralOp(image)],
      literalBytes: image.length,
      copyBytes: 0,
      node: node,
      queries: queries,
      rangesHashed: 0,
      shiftProbeBatches: 0,
      upToDate: false,
    );
  }

  final ops = <DeltaOp>[];

  /// Resolve one block's hit list into a COPY or a literal.
  void emit(int offset, int length, List<int> hits) {
    var best = -1;
    for (final hit in hits) {
      if (hit < 0 || hit + length > node.size) continue;
      if (best < 0 || (hit - offset).abs() < (best - offset).abs()) best = hit;
    }
    if (best >= 0) {
      ops.add(CopyOp(best, length));
      reused += length;
    } else {
      ops.add(LiteralOp(Uint8List.sublistView(image, offset, offset + length)));
      toSend += length;
    }
  }

  var offset = 0;
  while (offset < image.length) {
    if (cancel()) throw const RemoteDiffException('cancelled');
    final remaining = image.length - offset;
    if (remaining < blockSize) {
      // The node only hashes aligned blocks of at least four bytes, so a
      // shorter tail cannot be looked up: send it as-is.
      if (remaining < 4) {
        ops.add(LiteralOp(Uint8List.sublistView(image, offset)));
        toSend += remaining;
        offset = image.length;
        progress();
        break;
      }
      // Tail block: a single query with the exact remaining length.
      var length = remaining;
      if (length > 4) length = (length ~/ 4) * 4;
      final fingerprint = rolling64(image, offset, length);
      final wantedStart = offset > searchWindow ? offset - searchWindow : 0;
      final end = offset + length + searchWindow < node.size
          ? offset + length + searchWindow
          : node.size;
      // Once the new image is longer than the running image plus the search
      // window, the window starts past the end of the running image. The node
      // rejects start > end; clamp it so the query just finds nothing.
      final start = wantedStart > end ? end : wantedStart;
      final hits = await client.find(
          length: length,
          start: (start ~/ 4) * 4,
          end: (end ~/ 4) * 4,
          fingerprints: [fingerprint]);
      queries++;
      emit(offset, length, hits.isEmpty ? const [] : hits.first);
      if (length < remaining) {
        ops.add(LiteralOp(
            Uint8List.sublistView(image, offset + length, image.length)));
        toSend += remaining - length;
      }
      offset = image.length;
      progress();
      break;
    }

    // A batch of equally sized full blocks, all hashed in one flash scan.
    var count = remaining ~/ blockSize;
    if (count > blockFindMaxBlocks) count = blockFindMaxBlocks;
    final fingerprints = <int>[];
    final offsets = <int>[];
    for (var i = 0; i < count; i++) {
      final at = offset + i * blockSize;
      offsets.add(at);
      fingerprints.add(rolling64(image, at, blockSize));
    }
    final wantedStart = offset > searchWindow ? offset - searchWindow : 0;
    final last = offset + count * blockSize + searchWindow;
    final end = last < node.size ? last : node.size;
    final start = wantedStart > end ? end : wantedStart;
    final hitLists = await client.find(
        length: blockSize,
        start: (start ~/ 4) * 4,
        end: (end ~/ 4) * 4,
        fingerprints: fingerprints);
    queries++;
    for (var i = 0; i < fingerprints.length; i++) {
      emit(offsets[i], blockSize, i < hitLists.length ? hitLists[i] : const []);
    }
    offset += count * blockSize;
    progress();
  }

  await client.close();
  return RemoteDiffResult(
    ops: ops,
    literalBytes: toSend,
    copyBytes: reused,
    node: node,
    queries: queries,
    rangesHashed: queries,
    shiftProbeBatches: 0,
    upToDate: false,
  );
}
