import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'wire.dart';

// --- OP_BLOCK_HASH: read-only running-image hash oracle ---------------------
// Mirrors examples/simple_repeater/OtaUpdate.h. One request carries up to four
// ranges, so one REQ/RESPONSE exchange classifies up to four blocks. The
// metadata query (no ranges) returns the running image's size, its ESP segment
// table and its whole-image hash in one exchange.

const otaOpBlockHash = 0x09;
const otaOpBlockHashReport = 0x0A;
const otaOpBlockFind = 0x0B;
const otaOpBlockFindReport = 0x0C;

/// Feature bit in `OP_INFO_REPORT.features`. No layout change: old nodes simply
/// leave this bit clear.
const otaFeatBlockHash = 0x00000004;

const blockHashLength = 32;
const blockHashMaxRanges = 4;
const blockHashMaxSegments = 6;
const blockHashMaxRange = 32768;
const blockHashAlign = 4;
const blockFindMaxHits = 4;
const blockFindMaxBlocks = 12;
const blockFindHitsPer = 2;

const _blockHashMetaBody =
    4 + 1 + 1 + blockHashMaxSegments * 8 + blockHashLength;
const _blockHashRangeBody =
    4 + 1 + blockHashMaxRanges * (4 + 1 + blockHashLength);

/// Exact report frame lengths (magic + op + body + CRC), known from the
/// request. Passing these to [binaryResponseReport] avoids CRC-based zero-pad
/// ambiguity when a report's CRC happens to be 0x0000.
const blockHashMetaReportLen = 3 + _blockHashMetaBody + 2;
int blockHashRangeReportLen(int count) =>
    3 + 5 + count * (4 + 1 + blockHashLength) + 2;

/// Largest find-report frame (magic+op+count+hits+CRC).
const blockFindReportLenMax =
    3 + 1 + blockFindMaxBlocks * (1 + blockFindHitsPer * 4) + 2;

/// One (offset, length) probe. `length == 0` means "to the end of the image".
class BlockHashRange {
  const BlockHashRange(this.offset, this.length);

  final int offset;
  final int length;
}

/// A program segment of the running ESP image: the payload bytes, excluding
/// the 8-byte segment header.
class ImageSegment {
  const ImageSegment(this.offset, this.length);

  final int offset;
  final int length;
}

/// The node's answer to the metadata query.
class RunningImageInfo {
  const RunningImageInfo({
    required this.size,
    required this.segments,
    required this.sha256,
  });

  /// Length of the running app image including its appended digest — exactly
  /// the bytes [sha256] was taken over and the bytes a `.bin` contains.
  final int size;

  /// Up to [blockHashMaxSegments] payload segments, in image order.
  final List<ImageSegment> segments;

  /// SHA-256 over the whole [size] bytes; zeros when the node cannot hash.
  final Uint8List sha256;

  bool get canHash => size > 0;
}

/// Status byte for one range in an [BlockHashReport].
class BlockHashStatus {
  static const ok = 0;
  static const outOfBounds = 1;
  static const readFailed = 2;
  static const invalid = 3;
}

/// One range's answer: the echoed offset, a status and the hash (32 zero bytes
/// when the status is not [BlockHashStatus.ok]).
class BlockHashResult {
  const BlockHashResult(this.offset, this.status, this.sha256);

  final int offset;
  final int status;
  final Uint8List sha256;

  bool get ok => status == BlockHashStatus.ok;
}

/// A decoded OP_BLOCK_HASH_REPORT.
class BlockHashReport {
  const BlockHashReport(this.runningSize, this.results,
      {this.metadata, this.findOffsets});

  final int runningSize;
  final List<BlockHashResult> results;

  /// Present only for the metadata query (an empty range list).
  final RunningImageInfo? metadata;

  /// Present only for a find query: one offset list per requested block.
  final List<List<int>>? findOffsets;
}

int _le32(List<int> p, int at) =>
    p[at] | (p[at + 1] << 8) | (p[at + 2] << 16) | (p[at + 3] << 24);

void _putLe32(Uint8List p, int at, int value) {
  p[at] = value & 0xFF;
  p[at + 1] = (value >> 8) & 0xFF;
  p[at + 2] = (value >> 16) & 0xFF;
  p[at + 3] = (value >> 24) & 0xFF;
}

/// Build the request frame. An empty [ranges] list is the metadata query.
Uint8List buildBlockHashQuery(List<BlockHashRange> ranges) {
  assert(ranges.length <= blockHashMaxRanges);
  final body = Uint8List(1 + 8 * ranges.length);
  assert(body.length <= _blockHashRangeBody);
  body[0] = ranges.length;
  for (var i = 0; i < ranges.length; i++) {
    _putLe32(body, 1 + i * 8, ranges[i].offset);
    _putLe32(body, 5 + i * 8, ranges[i].length);
  }
  return buildOp(otaOpBlockHash, body: body);
}

/// Parse a report frame recovered from a PUSH_CODE_BINARY_RESPONSE. Returns
/// null for anything that is not a well-formed OP_BLOCK_HASH_REPORT.
BlockHashReport? parseBlockHashReport(List<int> payload) {
  // unpadFrame finds the shortest valid framed prefix; unwrapFrame then
  // removes its CRC (parseInfoReport/parseReport do the same two steps).
  final framed = unpadFrame(payload);
  final frame = framed == null ? null : unwrapFrame(framed);
  if (frame == null || frame.length < 3) return null;
  if (frame[2] != otaOpBlockHashReport) return null;
  final body = frame.sublist(3);
  if (body.length < 5) return null;
  final runningSize = _le32(body, 0);
  final count = body[4];

  if (count == 0) {
    if (body.length != _blockHashMetaBody) return null;
    final segCount =
        body[5] > blockHashMaxSegments ? blockHashMaxSegments : body[5];
    final segments = <ImageSegment>[];
    for (var i = 0; i < segCount; i++) {
      final at = 6 + i * 8;
      segments.add(ImageSegment(_le32(body, at), _le32(body, at + 4)));
    }
    final shaAt = 6 + blockHashMaxSegments * 8;
    return BlockHashReport(
      runningSize,
      const [],
      metadata: RunningImageInfo(
        size: runningSize,
        segments: segments,
        sha256:
            Uint8List.fromList(body.sublist(shaAt, shaAt + blockHashLength)),
      ),
    );
  }

  if (count > blockHashMaxRanges) return null;
  if (body.length != 5 + count * (4 + 1 + blockHashLength)) return null;
  final results = <BlockHashResult>[];
  for (var i = 0; i < count; i++) {
    final at = 5 + i * (4 + 1 + blockHashLength);
    results.add(BlockHashResult(
      _le32(body, at),
      body[at + 4],
      Uint8List.fromList(body.sublist(at + 5, at + 5 + blockHashLength)),
    ));
  }
  return BlockHashReport(runningSize, results);
}

/// Ask the node where a block fingerprint occurs in its running image. The
/// search is restricted to 4-byte-aligned offsets in [start, end).
Uint8List buildBlockFindQuery({
  required int length,
  required int start,
  required int end,
  required List<int> fingerprints,
}) {
  assert(fingerprints.isNotEmpty && fingerprints.length <= blockFindMaxBlocks);
  final body = Uint8List(13 + 8 * fingerprints.length);
  final bd = ByteData.sublistView(body);
  bd.setUint32(0, length, Endian.little);
  bd.setUint32(4, start, Endian.little);
  bd.setUint32(8, end, Endian.little);
  body[12] = fingerprints.length;
  for (var i = 0; i < fingerprints.length; i++) {
    bd.setUint64(13 + i * 8, fingerprints[i], Endian.little);
  }
  return buildOp(otaOpBlockFind, body: body);
}

/// Parse an OP_BLOCK_FIND_REPORT: the offsets where the block was found.
List<List<int>>? parseBlockFindReport(List<int> payload) {
  // Reports with few hits can be shorter than unpadFrame's 7-byte minimum,
  // so trim the crypto padding with the CRC directly.
  Uint8List? framed;
  for (var len = payload.length; len >= 5; len--) {
    final cand = Uint8List.fromList(payload.sublist(0, len));
    if (unwrapFrame(cand) != null) {
      framed = cand;
      break;
    }
    if (payload[len - 1] != 0) break;
  }
  final frame = framed == null ? null : unwrapFrame(framed);
  if (frame == null || frame.length < 5 || frame[2] != otaOpBlockFindReport) {
    return null;
  }
  final count = frame[3];
  if (count == 0 || count > blockFindMaxBlocks) return null;
  final result = <List<int>>[];
  var at = 4;
  for (var i = 0; i < count; i++) {
    if (at >= frame.length) return null;
    final hits = frame[at++];
    if (hits > blockFindHitsPer || at + hits * 4 > frame.length) return null;
    final offsets = <int>[];
    for (var j = 0; j < hits; j++) {
      offsets.add(_le32(frame, at));
      at += 4;
    }
    result.add(offsets);
  }
  if (at != frame.length) return null;
  return result;
}

/// Thrown when the node does not answer a block-hash query.
class BlockHashException implements Exception {
  const BlockHashException(this.message);

  final String message;

  @override
  String toString() => 'BlockHashException: $message';
}

/// One request/response client for the hash oracle. Like OP_ASK, the reply
/// arrives as a PUSH_CODE_BINARY_RESPONSE scoped to the contact's pubkey and
/// the request tag; only one query is in flight at a time.
class BlockHashClient {
  BlockHashClient({
    required this.link,
    required this.contact,
    this.timeout = const Duration(seconds: 10),
    this.retries = 3,
  });

  final RadioLink link;
  final Contact contact;
  final Duration timeout;
  final int retries;

  StreamSubscription<Uint8List>? _sub;
  Completer<BlockHashReport>? _waiter;
  int? _tag;
  int? _expectedLen;
  bool _isFind = false;

  Future<BlockHashReport> query(List<BlockHashRange> ranges) async {
    if (ranges.isEmpty) return _queryOnce(ranges);
    Object? last;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        return await _queryOnce(ranges);
      } on BlockHashException catch (e) {
        last = e;
      }
    }
    throw last ?? const BlockHashException('no answer from the node');
  }

  Future<RunningImageInfo> metadata() async {
    final report = await query(const []);
    final info = report.metadata;
    if (info == null) throw const BlockHashException('bad metadata report');
    return info;
  }

  /// Locate up to [blockFindMaxBlocks] blocks in one flash scan.
  Future<List<List<int>>> find({
    required int length,
    required int start,
    required int end,
    required List<int> fingerprints,
  }) async {
    Object? last;
    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        return await _findOnce(
            length: length, start: start, end: end, fingerprints: fingerprints);
      } on BlockHashException catch (e) {
        last = e;
      }
    }
    throw last ?? const BlockHashException('no answer from the node');
  }

  Future<List<List<int>>> _findOnce({
    required int length,
    required int start,
    required int end,
    required List<int> fingerprints,
  }) async {
    final waiter = Completer<BlockHashReport>();
    _waiter = waiter;
    _tag = null;
    _isFind = true;
    _sub ??= link.pushes.listen(_onPush);
    try {
      final frame = buildBlockFindQuery(
          length: length, start: start, end: end, fingerprints: fingerprints);
      final sent = await link
          .sendBinaryRequest(contact, [reqTypeOta, frame.length, ...frame]);
      _tag = sent.tag;
      final report = await waiter.future.timeout(timeout);
      return report.findOffsets?.cast<List<int>>() ?? const [];
    } on TimeoutException {
      throw const BlockHashException('no answer from the node');
    } finally {
      _waiter = null;
      _tag = null;
      _isFind = false;
    }
  }

  Future<BlockHashReport> _queryOnce(List<BlockHashRange> ranges) async {
    final waiter = Completer<BlockHashReport>();
    _waiter = waiter;
    _tag = null;
    _isFind = false;
    _expectedLen = ranges.isEmpty
        ? blockHashMetaReportLen
        : blockHashRangeReportLen(ranges.length);
    _sub ??= link.pushes.listen(_onPush);
    try {
      final frame = buildBlockHashQuery(ranges);
      final sent = await link
          .sendBinaryRequest(contact, [reqTypeOta, frame.length, ...frame]);
      _tag = sent.tag;
      final report = await waiter.future.timeout(timeout);
      if (report.results.length != ranges.length) {
        throw const BlockHashException('report range count mismatch');
      }
      return report;
    } on TimeoutException {
      throw const BlockHashException('no answer from the node');
    } finally {
      _waiter = null;
      _tag = null;
    }
  }

  void _onPush(Uint8List frame) {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) return;
    if (_isFind) {
      // Hit counts are in the reply, so its length varies. Try each possible
      // exact frame length rather than letting CRC-based unpadding guess
      // through zero padding in a report whose CRC is small.
      final maxLen = frame.length - 6;
      for (var len = maxLen; len >= 5; len--) {
        final payload = binaryResponseReport(frame,
            contactPubKey: contact.publicKey, askTag: _tag, exactLength: len);
        if (payload == null) continue;
        final offsets = parseBlockFindReport(payload);
        if (offsets == null) continue;
        _waiter = null;
        waiter.complete(BlockHashReport(0, const [], findOffsets: offsets));
        return;
      }
      return;
    }
    final payload = binaryResponseReport(frame,
        contactPubKey: contact.publicKey,
        askTag: _tag,
        exactLength: _expectedLen);
    if (payload == null) return;
    final report = parseBlockHashReport(payload);
    if (report == null) return;
    _waiter = null;
    waiter.complete(report);
  }

  Future<void> close() async {
    await _sub?.cancel();
    _sub = null;
  }
}
