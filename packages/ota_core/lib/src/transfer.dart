import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'delta.dart';
import 'wire.dart';

/// Phase of the transfer, for progress display.
enum TransferPhase { arming, sending, done, failed }

/// Progress snapshot for the UI. Counted in wire packets.
class TransferProgress {
  const TransferProgress({
    required this.phase,
    required this.opsApplied,
    required this.opsTotal,
    required this.packetsSent,
    required this.literalBytesSent,
    required this.retries,
    required this.elapsed,
  });

  final TransferPhase phase;

  /// Ops the node reports applied (`next_expected - 1`), or null before the
  /// first report. START counts as op 0.
  final int? opsApplied;

  final int opsTotal;
  final int packetsSent;

  /// Total LITERAL payload bytes handed to the radio (includes re-sends).
  final int literalBytesSent;

  final int retries;
  final Duration elapsed;

  double? get fraction =>
      opsApplied == null || opsTotal == 0 ? null : opsApplied! / opsTotal;
}

/// Result of a completed transfer.
class TransferResult {
  const TransferResult({
    required this.packetsSent,
    required this.retries,
    required this.elapsed,
    required this.uniqueOps,
    required this.duplicateOps,
    required this.literalBytesSent,
    required this.uniqueLiteralBytes,
  });

  final int packetsSent;
  final int retries;
  final Duration elapsed;

  /// Op frames that make up the image, sent once each (`OP_START` excluded).
  final int uniqueOps;

  /// Op frames broadcast a second (or further) time, i.e. recovered from a gap.
  final int duplicateOps;

  /// Op packets relative to the minimum: 1.0 means each frame went out once.
  double get opAmplification =>
      uniqueOps == 0 ? 1.0 : (uniqueOps + duplicateOps) / uniqueOps;

  /// LITERAL bytes handed to the radio, including every re-send.
  final int literalBytesSent;

  /// LITERAL bytes that make up the image once.
  final int uniqueLiteralBytes;

  /// How many times each literal byte was broadcast on average: 1.0 is
  /// perfect, 2.0 means every byte went out twice. This is the efficiency
  /// measure that matters — airtime is bytes, and a byte sent twice is a byte
  /// the mesh could have used.
  double get amplification =>
      uniqueLiteralBytes == 0 ? 1.0 : literalBytesSent / uniqueLiteralBytes;

  /// Whole-number form for display: "1.07x".
  String get amplificationLabel => '${amplification.toStringAsFixed(2)}x';
}

class OtaTransferException implements Exception {
  OtaTransferException(this.message);

  final String message;

  @override
  String toString() => 'OtaTransferException: $message';
}

/// The `ota stage` contract the operator armed, handed to the transfer
/// verbatim. The node arms exactly this image and nothing else.
class OtaStartContract {
  const OtaStartContract({
    required this.imageSize,
    required this.imageSha256,
    required this.targetId,
    required this.token,
  });

  final int imageSize;
  final List<int> imageSha256;

  /// 4-byte target id (`sha256(pio_env)[0..3]` LE — see
  /// [targetIdForEnvironment]).
  final int targetId;

  /// The arm token from the `ota stage` reply.
  final int token;
}

/// The DIRECT route to the target node.
class OtaRoute {
  const OtaRoute({
    required this.path,
    required this.encodedPathLen,
    required this.retPath,
    required this.retPathLen,
  });

  /// Route on the wire (consumed hop by hop). Empty = zero hop.
  final Uint8List path;

  /// Encoded path_len byte for [path].
  final int encodedPathLen;

  /// Return itinerary for OP_REPORT frames, in repeater→app order
  /// (encoded like a path_len byte). Empty = zero hop.
  final Uint8List retPath;
  final int retPathLen;

  /// Zero-hop route.
  OtaRoute.zeroHop()
      : path = Uint8List(0),
        encodedPathLen = 0,
        retPath = Uint8List(0),
        retPathLen = 0;

  /// Build the route from a contact's DIRECT path, reversing it for the
  /// return leg. Throws when the contact has no direct route.
  factory OtaRoute.fromContactPath({
    required int outPathLen,
    required Uint8List outPath,
  }) {
    if (outPathLen == 0xFF || outPathLen < 0) {
      throw OtaTransferException(
          'contact has no direct route — set the route first');
    }
    final hashSize = PathUtils.getHashSize(outPathLen);
    final count = PathUtils.getHashCount(outPathLen);
    final byteLength = PathUtils.getByteLength(outPathLen);
    if (outPath.length < byteLength) {
      throw OtaTransferException('contact path is truncated');
    }
    final path = Uint8List.fromList(outPath.sublist(0, byteLength));
    // The return itinerary travels repeater → app: reverse the hop order,
    // keeping the same hash size.
    final ret = Uint8List(byteLength);
    for (int i = 0; i < count; i++) {
      final src = (count - 1 - i) * hashSize;
      final dst = i * hashSize;
      ret.setRange(dst, dst + hashSize, path.sublist(src, src + hashSize));
    }
    return OtaRoute(
      path: path,
      encodedPathLen: outPathLen,
      retPath: ret,
      retPathLen: PathUtils.encodePathLen(hashSize, count),
    );
  }
}

/// The wire-ready op stream derived from a [computeDelta] result.
///
/// Seq numbering is assigned here: START is seq 0; each op takes the next
/// seq; OP_END is last. LITERALs are split to [otaLiteralChunk] bytes.
///
/// Protocol gotcha (mirrors the firmware): OP_END is *applied* but does not
/// advance the node's `next_expected` watermark — it bumps only while
/// staging. Once every op except OP_END landed, the node's report is
/// `frames.length`, which is therefore the completion signal for transfer
/// purposes; whether OP_END actually landed is confirmed by the following
/// `ota status` poll (state=ready), which the app must do anyway.
class WireOps {
  WireOps(this.frames);

  /// Op frames in seq order (START is not included; it is armed separately).
  final List<Uint8List> frames;

  /// The `next_expected` value the node reports once every op except
  /// OP_END has been applied.
  int get completeNextExpected => frames.length;

  /// LITERAL payload bytes in the stream exactly once — the useful work.
  /// Sent bytes divided by this is the broadcast amplification.
  late final int uniqueLiteralBytes = frames.fold<int>(0, (sum, f) {
    if (f.length < 7 || f[2] != otaOpLiteral) return sum;
    return sum + (f[5] | (f[6] << 8));
  });
}

/// Derive the wire-ready op stream from delta ops.
///
/// [literalChunk] is the most data bytes one OP_LITERAL may carry. The default
/// is the pure on-air maximum, but a packet sent through a stock companion
/// must fit the companion's frame (see [otaLiteralChunkForCompanion]), which is
/// usually the tighter bound — an oversized frame is dropped silently by the
/// companion, so the op never lands and the transfer stalls.
WireOps wireOpsFor(List<DeltaOp> ops, {int literalChunk = otaLiteralChunk}) {
  assert(literalChunk >= 1 && literalChunk <= otaLiteralChunk);
  final frames = <Uint8List>[];
  var seq = 1;
  for (final op in ops) {
    switch (op) {
      case CopyOp(:final baseOffset, :final length):
        frames.add(buildCopy(seq: seq, baseOffset: baseOffset, length: length));
        seq++;
      case LiteralOp(:final data):
        var offset = 0;
        while (offset < data.length) {
          final end = offset + literalChunk;
          frames.add(buildLiteralChunk(
            seq: seq,
            data: Uint8List.sublistView(
                data, offset, end > data.length ? data.length : end),
          ));
          seq++;
          offset += literalChunk;
        }
    }
  }
  frames.add(buildEnd(seq: seq));
  return WireOps(frames);
}

/// Windowed op-stream sender with OP_ASK/OP_REPORT recovery.
///
/// The node applies ops strictly in seq order and drops anything else, so
/// recovery is "re-send from next_expected" after each ask. DIRECT routing
/// delivers in order per path; the path is consumed hop by hop, so the ask
/// carries the return itinerary explicitly (never stored by the node).
class OtaTransfer {
  OtaTransfer({
    required this.link,
    required this.route,
    required this.contract,
    required this.ops,
    this.windowSize = 12,
    this.askTimeout = const Duration(seconds: 10),
    this.maxRetriesPerWindow = 12,
    this.opSpacing = const Duration(milliseconds: 25),
    this.resumeFrom = 1,
    this.askSettle = const Duration(milliseconds: 250),
    this.maxReasks = 1,
    this.maxResendRounds = 12,
    this.companionFrameLimit = otaStockCompanionFrameLimit,
    this.shouldCancel,
  })  : assert(windowSize >= 1),
        wireOps = wireOpsFor(ops,
            literalChunk: otaLiteralChunkForCompanion(
                pathBytes: route.path.length,
                frameLimit: companionFrameLimit)) {
    if (resumeFrom > 1) {
      // Include the already-sent prefix in the cumulative transfer metrics.
      // The session is still the same update: those bytes went out before the
      // link dropped and must count toward amplification.
      packetsSent = resumeFrom;
      final prefixEnd = (resumeFrom - 1).clamp(0, wireOps.frames.length);
      for (var i = 0; i < prefixEnd; i++) {
        final frame = wireOps.frames[i];
        if (frame.length >= 7 && frame[2] == otaOpLiteral) {
          literalBytesSent += frame[5] | (frame[6] << 8);
        }
      }
    }
  }

  final RadioLink link;
  final OtaRoute route;
  final OtaStartContract contract;
  final List<DeltaOp> ops;

  final WireOps wireOps;

  /// Ops per window. The companion's raw-TX pool is small; keep this under
  /// it. Duty cycle, not the pool, is the real limiter.
  final int windowSize;

  final Duration askTimeout;
  final int maxRetriesPerWindow;

  /// Small spacing between queued writes to spare the companion's TX pool.
  final Duration opSpacing;

  /// Cheap asks per window spent waiting for the node to catch up before one
  /// re-broadcast round. One is enough: it covers a node that is still
  /// committing the tail of the window, and waiting longer does not help when
  /// an op was genuinely lost — measured on hardware, extra patience just
  /// delayed the recovery that actually worked.
  final int maxReasks;

  /// Re-broadcast rounds per window before the transfer gives up. Each round
  /// re-sends only what the node reports missing.
  final int maxResendRounds;

  /// First op sequence to send, when resuming a session the node already has.
  ///
  /// The node reports `next_expected` and applies ops strictly in order, so a
  /// transfer interrupted by a lost link (a phone's BLE drop, a TCP reset)
  /// resumes by continuing from that seq — no re-arming, no re-sending what
  /// already landed. 1 means "start from the beginning".
  final int resumeFrom;

  /// How long to let the tail of a window finish transmitting and committing
  /// before the first ask. Asking too early is not an error — the node just
  /// reports a lower `next_expected` — but it invites a pointless re-send.
  final Duration askSettle;

  /// Largest companion transport frame this transfer may produce
  /// (`MAX_FRAME_SIZE` in the stock firmware, after the 3-byte serial header).
  /// Commands over this are dropped by the companion without an error, so the
  /// literal chunk size is derived from it. Raise it only for a transport
  /// known to carry more.
  final int companionFrameLimit;

  /// Checked alongside [cancel] at every op boundary — lets a UI bind a
  /// cancel flag without holding a reference to this engine.
  final bool Function()? shouldCancel;

  int packetsSent = 0;
  int literalBytesSent = 0;
  int retries = 0;

  /// Op frames re-broadcast beyond their first transmission.
  int _duplicateOps = 0;

  final _sw = Stopwatch();
  bool _cancelRequested = false;
  Completer<OtaReport>? _reportWaiter;
  OtaReport? _lastReport;
  StreamSubscription<Uint8List>? _reportSub;
  void Function(TransferProgress)? onProgress;

  /// Request cancellation. The current write finishes (or fails); the caller
  /// decides whether to `ota abort` the staged slot afterwards.
  void cancel() => _cancelRequested = true;

  bool get cancelRequested => _cancelRequested;

  /// Run the transfer to completion. Throws [OtaTransferException] on failure
  /// (including cancellation — check [cancelRequested] to distinguish).
  Future<TransferResult> run(
      {void Function(TransferProgress)? onProgress}) async {
    this.onProgress = onProgress;
    _sw
      ..reset()
      ..start();
    _reportSub = link.pushes.listen(_onPush);
    try {
      if (resumeFrom > 1) {
        // Resuming: the node keeps its staged bytes and its arm is consumed.
        _emitProgress(
          phase: TransferPhase.sending,
          opsApplied: resumeFrom - 1,
          literalBytes: literalBytesSent,
        );
      }
      final start = buildStart(
        size: contract.imageSize,
        sha256: contract.imageSha256,
        targetId: contract.targetId,
        token: contract.token,
      );
      if (resumeFrom <= 1) await _sendOp(start);

      // Send the stream in windows; after each window, ask for the report and
      // re-send from next_expected on any gap.
      var cursor = (resumeFrom - 1).clamp(0, wireOps.frames.length);
      while (cursor < wireOps.frames.length) {
        _throwIfCancelled();
        final windowEnd = (cursor + windowSize).clamp(0, wireOps.frames.length);
        for (var i = cursor; i < windowEnd; i++) {
          _throwIfCancelled();
          await _sendOp(wireOps.frames[i], opIndex: i + 1);
        }
        final windowStart = cursor;
        cursor = windowEnd;
        final applied = await _askUntilInSync(windowStart, cursor);
        _emitProgress(
          phase: TransferPhase.sending,
          opsApplied: applied - 1, // next_expected counts START as applied
          literalBytes: literalBytesSent,
        );
      }
      return TransferResult(
        packetsSent: packetsSent,
        retries: retries,
        elapsed: _sw.elapsed,
        uniqueOps: wireOps.frames.length,
        duplicateOps: _duplicateOps,
        literalBytesSent: literalBytesSent,
        uniqueLiteralBytes: wireOps.uniqueLiteralBytes,
      );
    } finally {
      await _reportSub?.cancel();
      _reportSub = null;
      _reportWaiter = null;
      _sw.stop();
    }
  }

  /// Acknowledge a window: ask patiently first, re-broadcast only as a last
  /// resort.
  ///
  /// A stock companion acknowledges `sendRawPacket` when the packet is *queued*,
  /// not when it leaves the radio, and the node's flash write also stalls its
  /// receiver. So the first ask after a window can legitimately report a
  /// `next_expected` behind the window: those ops are in flight or still being
  /// committed, not lost. An ask costs ~25 bytes of airtime and a re-sent op
  /// ~180, so it is worth [maxReasks] asks before one re-broadcast round, and a
  /// round only re-sends from what the node reports missing.
  Future<int> _askUntilInSync(int windowStart, int windowEnd) async {
    // OP_END does not advance the node's next_expected watermark (the raw
    // firmware bumps it only while staging), so once END has been sent the
    // report can never exceed frames.length. Everything except END landed
    // iff the node reports frames.length.
    final target = windowEnd < wireOps.frames.length
        ? windowEnd + 1
        : wireOps.frames.length;
    // First op of this window: what a stalled node still needs starts here.
    var missing = windowStart + 1;
    var stalledAsks = 0; // consecutive answers that showed no progress
    var failedAsks = 0; // asks that got no answer at all
    var rounds = 0;
    while (true) {
      _throwIfCancelled();
      if (rounds == 0 &&
          stalledAsks == 0 &&
          failedAsks == 0 &&
          askSettle > Duration.zero) {
        await Future<void>.delayed(askSettle);
      }
      await _ask();
      final report = _lastReport;
      if (report == null) {
        // A lost ask is not evidence about the node: just ask again.
        retries++;
        if (++failedAsks > maxRetriesPerWindow) {
          throw OtaTransferException(
              'no report from the node after $failedAsks asks');
        }
        continue;
      }
      failedAsks = 0;
      if (report.nextExpected >= target) return report.nextExpected;
      if (report.nextExpected > missing) {
        missing = report.nextExpected; // it committed more: it is catching up
        stalledAsks = 0;
        continue;
      }
      if (++stalledAsks <= maxReasks) continue;
      // Stalled: re-broadcast exactly what it does not have.
      if (++rounds > maxResendRounds) break;
      stalledAsks = 0;
      var resumeIdx = missing - 1;
      if (resumeIdx >= wireOps.frames.length) return missing;
      // Alternate rounds start one frame earlier. A retry that always sends the
      // same bytes in the same order can lock step with a periodic loss pattern
      // and never get through; one extra frame (which the node drops as an
      // already-applied seq) shifts the phase. Costs ~180 bytes only while
      // stalled.
      if (rounds.isOdd && resumeIdx > windowStart) resumeIdx--;
      for (var i = resumeIdx; i < windowEnd && i < wireOps.frames.length; i++) {
        _throwIfCancelled();
        await _sendOp(wireOps.frames[i]);
        _duplicateOps++;
        retries++;
      }
    }
    throw OtaTransferException('node did not acknowledge ops in this window '
        '(stalled at op $missing of $target)');
  }

  /// Send OP_ASK and wait for the corresponding OP_REPORT. Leaves _lastReport
  /// null when no report arrives within [askTimeout].
  Future<void> _ask() async {
    final waiter = Completer<OtaReport>();
    _reportWaiter = waiter;
    final ask = buildAsk(retPathLen: route.retPathLen, retPath: route.retPath);
    await _sendOp(ask);
    try {
      _lastReport = await waiter.future.timeout(askTimeout);
    } on TimeoutException {
      _lastReport = null;
    } finally {
      _reportWaiter = null;
    }
  }

  Future<void> _sendOp(Uint8List otaFrame, {int? opIndex}) async {
    final raw = PacketBuilder.createRawCustom(
      otaFrame,
      path: route.path,
      encodedPathLen: route.encodedPathLen,
    );
    await link.sendRawPacket(raw.writeTo());
    packetsSent++;
    if (otaFrame.length > 2 && otaFrame[2] == otaOpLiteral) {
      literalBytesSent += (otaFrame[5] | (otaFrame[6] << 8));
    }
    if (opSpacing > Duration.zero) {
      await Future<void>.delayed(opSpacing);
    }
  }

  void _onPush(Uint8List frame) {
    if (frame.isEmpty || frame[0] != pushCodeLogRxData) return;
    final raw = RawRxFrame.parse(frame);
    if (raw == null) return;
    final packet = Packet.readFrom(raw.raw);
    if (packet == null || packet.payloadType != payloadTypeRawCustom) return;
    if (packet.payload.isEmpty) return;
    final report = parseReport(packet.payload);
    if (report == null) return;
    _lastReport = report;
    final waiter = _reportWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _reportWaiter = null;
      waiter.complete(report);
    }
  }

  void _throwIfCancelled() {
    if (_cancelRequested || (shouldCancel?.call() ?? false)) {
      throw OtaTransferException('cancelled');
    }
  }

  void _emitProgress({
    required TransferPhase phase,
    required int? opsApplied,
    required int literalBytes,
  }) {
    onProgress?.call(TransferProgress(
      phase: phase,
      opsApplied: opsApplied,
      opsTotal: wireOps.frames.length - 1,
      packetsSent: packetsSent,
      literalBytesSent: literalBytes,
      retries: retries,
      elapsed: _sw.elapsed,
    ));
  }
}
