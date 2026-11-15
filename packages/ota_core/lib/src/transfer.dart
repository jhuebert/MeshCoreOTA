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
  });

  final int packetsSent;
  final int retries;
  final Duration elapsed;
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
      throw OtaTransferException('contact has no direct route — set the route first');
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
}

/// Derive the wire-ready op stream from delta ops.
WireOps wireOpsFor(List<DeltaOp> ops) {
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
          final end = offset + otaLiteralChunk;
          frames.add(buildLiteralChunk(
            seq: seq,
            data: Uint8List.sublistView(data, offset, end > data.length ? data.length : end),
          ));
          seq++;
          offset += otaLiteralChunk;
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
  })  : assert(windowSize >= 1),
        wireOps = wireOpsFor(ops);

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

  int packetsSent = 0;
  int literalBytesSent = 0;
  int retries = 0;

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
  Future<TransferResult> run({void Function(TransferProgress)? onProgress}) async {
    this.onProgress = onProgress;
    _sw
      ..reset()
      ..start();
    _reportSub = link.pushes.listen(_onPush);
    try {
      final start = buildStart(
        size: contract.imageSize,
        sha256: contract.imageSha256,
        targetId: contract.targetId,
        token: contract.token,
      );
      await _sendOp(start);

      // Send the stream in windows; after each window, ask for the report and
      // re-send from next_expected on any gap.
      var cursor = 0;
      while (cursor < wireOps.frames.length) {
        _throwIfCancelled();
        final windowEnd = (cursor + windowSize).clamp(0, wireOps.frames.length);
        for (var i = cursor; i < windowEnd; i++) {
          _throwIfCancelled();
          await _sendOp(wireOps.frames[i], opIndex: i + 1);
        }
        cursor = windowEnd;
        final applied = await _askUntilInSync(cursor);
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
      );
    } finally {
      await _reportSub?.cancel();
      _reportSub = null;
      _reportWaiter = null;
      _sw.stop();
    }
  }

  /// Ask after a window; re-send from the node's next_expected until the
  /// node reports past the ops we just sent (or retries run out).
  Future<int> _askUntilInSync(int windowEnd) async {
    // OP_END does not advance the node's next_expected watermark (the raw
    // firmware bumps it only while staging), so once END has been sent the
    // report can never exceed frames.length. Everything except END landed
    // iff the node reports frames.length.
    final target = windowEnd < wireOps.frames.length
        ? windowEnd + 1
        : wireOps.frames.length;
    for (var attempt = 0; attempt < maxRetriesPerWindow; attempt++) {
      _throwIfCancelled();
      await _ask();
      final report = _lastReport;
      if (report == null) {
        retries++; // no answer this round
        continue;
      }
      if (report.nextExpected >= target) {
        return report.nextExpected;
      }
      // Node is behind; re-send exactly what it is missing.
      final resumeIdx = report.nextExpected - 1;
      if (resumeIdx >= wireOps.frames.length) return report.nextExpected;
      for (var i = resumeIdx; i < windowEnd && i < wireOps.frames.length; i++) {
        _throwIfCancelled();
        await _sendOp(wireOps.frames[i]);
        retries++;
      }
    }
    throw OtaTransferException(
        'node did not acknowledge ops in this window after $maxRetriesPerWindow asks');
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
    if (_cancelRequested) {
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
