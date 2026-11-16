import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

/// Mirror of the fork firmware's op interpreter (examples/simple_repeater/
/// OtaUpdate.cpp) closely enough to validate the wire contract end to end:
/// strict seq order, pending-arm contract, bounds checks, SHA-256 gate at
/// OP_END. Any divergence here means the Dart wire code is wrong.
enum FakeNodeState { idle, staging, ready, error }

class FakeOtaNode {
  FakeOtaNode({
    required this.running,
    required this.slotSize,
    required this.targetId,
  });

  final Uint8List running;
  final int slotSize;
  final int targetId;

  FakeNodeState state = FakeNodeState.idle;
  int err = 0;
  int _expect = 1;
  int _written = 0;
  int _size = 0;
  List<int> _expectedSha = const <int>[];
  Uint8List _slot = Uint8List(0);
  int pendingSize = 0;
  List<int> pendingSha = const <int>[];
  int pendingToken = -1;
  int lastAskRetPathLen = 0;

  /// Ops whose bytes have been written, i.e. what the node could report.
  int _received = 1;

  /// Ops committed per ask. Big by default (a commit is instant); a test can
  /// lower it to model a flash write that delays the watermark.
  int commitPerAsk = 1 << 30;
  int asks = 0;

  bool get stagingArmed =>
      state == FakeNodeState.staging || state == FakeNodeState.ready;
  int get nextExpected => _expect & 0xFFFF;
  Uint8List get stagedImage => Uint8List.sublistView(_slot, 0, _written);

  void arm({required int size, required List<int> sha256, required int token}) {
    pendingSize = size;
    pendingSha = sha256;
    pendingToken = token;
  }

  List<Uint8List> handlePacket(Uint8List frame) {
    final body = unwrapFrame(frame);
    if (body == null) {
      return const [];
    }
    final op = body[2];

    if (op == otaOpAsk) {
      lastAskRetPathLen = body.length > 3 ? body[3] : 0;
      if (!stagingArmed) return const [];
      asks++;
      // Work through the write queue: commit up to [commitPerAsk] received ops.
      final commitTo = _expect + commitPerAsk > _received
          ? _received
          : _expect + commitPerAsk;
      _expect = commitTo;
      return [
        buildOp(otaOpReport, body: [_expect & 0xFF, (_expect >> 8) & 0xFF]),
      ];
    }
    if (op == otaOpNop || op == otaOpReport) return const [];

    final seq = body[3] | (body[4] << 8);

    if (op == otaOpStart) {
      if (seq != 0) {
        err = 6;
        return const [];
      }
      if (state != FakeNodeState.idle) return const [];
      final bd = ByteData.sublistView(body, 5);
      final size = bd.getUint32(0, Endian.little);
      final sha = body.sublist(9, 41);
      final target = bd.getUint32(36, Endian.little);
      final token = bd.getUint32(40, Endian.big);
      if (target != targetId) {
        err = 1;
        return const [];
      }
      if (size == 0 || size > slotSize) {
        err = 3;
        return const [];
      }
      if (token != pendingToken ||
          size != pendingSize ||
          !_bytesEqual(sha, pendingSha)) {
        err = 7;
        return const [];
      }
      pendingToken = -1; // single use
      state = FakeNodeState.staging;
      _slot = Uint8List(size);
      _size = size;
      _written = 0;
      _expectedSha = List<int>.from(sha);
      _expect = 1;
      _received = 1;
      err = 0;
      return const [];
    }

    if (!stagingArmed) return const [];
    if (seq != _received)
      return const []; // strictly in order; everything else is dropped

    if (op == otaOpCopy) {
      final bd = ByteData.sublistView(body, 5);
      final baseOffset = bd.getUint32(0, Endian.little);
      final len = bd.getUint16(4, Endian.little);
      if (baseOffset + len > running.length || _written + len > _size) {
        err = 6;
        state = FakeNodeState.error;
        return const [];
      }
      _slot.setRange(_written, _written + len,
          running.sublist(baseOffset, baseOffset + len));
      _written += len;
      _received++;
      return const [];
    }

    if (op == otaOpLiteral) {
      final len = body[5] | (body[6] << 8);
      if (body.length < 7 + len || _written + len > _size) {
        err = 6;
        state = FakeNodeState.error;
        return const [];
      }
      _slot.setRange(_written, _written + len, body.sublist(7, 7 + len));
      _written += len;
      _received++;
      return const [];
    }

    if (op == otaOpEnd) {
      final digest = sha256.convert(stagedImage).bytes;
      if (_bytesEqual(digest, _expectedSha)) {
        state = FakeNodeState.ready;
      } else {
        state = FakeNodeState.error;
        err = 4;
      }
      return const [];
    }

    return const [];
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

const _testTargetId = 0x9F19BCD1; // Xiao_S3_WIO_repeater (sha256 prefix LE)

Uint8List _sha256Bytes(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

Uint8List _logRxFrame(Uint8List packet) =>
    Uint8List.fromList([0x88, 24, 0xBA, ...packet]); // 6.0 dB snr, -70 dBm rssi

Uint8List? _otaPayload(Uint8List packetBytes) {
  final pkt = Packet.readFrom(packetBytes);
  if (pkt == null || pkt.payloadType != payloadTypeRawCustom) return null;
  return Uint8List.fromList(pkt.payload);
}

Uint8List _mutate(Uint8List base, Random random, {int edits = 40}) {
  final target = Uint8List.fromList(base);
  for (var i = 0; i < edits; i++) {
    target[random.nextInt(target.length)] = random.nextInt(256);
  }
  return target;
}

class _Harness {
  _Harness();

  late FakeDeviceLink link;
  late FakeOtaNode node;

  void wire({
    required Uint8List base,
    required Uint8List target,
    int dropEveryNth = 0,
    int? dropPercent,
    int slotSize = 262144,
  }) {
    node =
        FakeOtaNode(running: base, slotSize: slotSize, targetId: _testTargetId);
    link = FakeDeviceLink(snr: 6.0, rssi: -70);
    if (dropEveryNth > 0) link.dropEveryNthTx = dropEveryNth;
    if (dropPercent != null) {
      // Scattered loss (deterministic): a strictly periodic pattern can lock
      // step with a fixed retry cadence, which real air loss never does.
      link.dropPredicate = (n) => (n * 2654435761) % 100 < dropPercent;
    }
  }

  OtaTransfer makeTransfer({
    required Uint8List target,
    required Uint8List base,
    int token = 0xBADC0FFE,
    int windowSize = 4,
  }) {
    node.arm(
      size: target.length,
      sha256: _sha256Bytes(target),
      token: token,
    );
    link.txHandler = (packet, _) async {
      final payload = _otaPayload(packet);
      if (payload != null) {
        for (final response in node.handlePacket(payload)) {
          final reply = PacketBuilder.createRawCustom(
            response,
            path: const [],
          ).writeTo();
          link.simulatePush(_logRxFrame(reply));
        }
      }
      return true;
    };
    final ops = computeDelta(base, target).ops;
    return OtaTransfer(
      link: link,
      route: OtaRoute.zeroHop(),
      contract: OtaStartContract(
        imageSize: target.length,
        imageSha256: _sha256Bytes(target),
        targetId: _testTargetId,
        token: token,
      ),
      ops: ops,
      windowSize: windowSize,
      askTimeout: const Duration(milliseconds: 200),
      maxRetriesPerWindow: 32,
      opSpacing: Duration.zero,
      askSettle: Duration.zero,
    );
  }
}

void main() {
  final random = Random(0xC0FFEE);

  test('a clean transfer stages the exact image', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 31 + 7) & 0xFF));
    final target = _mutate(base, random);
    harness.wire(base: base, target: target);
    final transfer = harness.makeTransfer(target: target, base: base);
    final progress = <TransferProgress>[];
    final result = await transfer.run(onProgress: progress.add);
    expect(harness.node.state, FakeNodeState.ready);
    expect(harness.node.stagedImage, target);
    expect(result.packetsSent, greaterThan(0));
    expect(progress, isNotEmpty);
    expect(progress.last.fraction, 1.0);
  });

  test('deterministic packet loss still converges', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 13 + 5) & 0xFF));
    final target = _mutate(base, random);
    harness.wire(base: base, target: target, dropPercent: 12);
    final transfer =
        harness.makeTransfer(target: target, base: base, windowSize: 4);
    final result = await transfer.run();
    expect(harness.node.state, FakeNodeState.ready);
    expect(harness.node.stagedImage, target);
    expect(result.retries, greaterThan(0));
  });

  test('wrong arm token: node stays idle and the transfer fails', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(List<int>.generate(2048, (i) => i & 0xFF));
    final target = _mutate(base, random, edits: 10);
    harness.wire(base: base, target: target);
    harness.node.arm(
      size: target.length,
      sha256: _sha256Bytes(target),
      token: 0x11111111, // the arm the operator would actually approve
    );
    harness.link.txHandler = (packet, _) async {
      final payload = _otaPayload(packet);
      if (payload != null) {
        for (final response in harness.node.handlePacket(payload)) {
          harness.link.simulatePush(
            _logRxFrame(PacketBuilder.createRawCustom(response).writeTo()),
          );
        }
      }
      return true;
    };
    final ops = computeDelta(base, target).ops;
    final transfer = OtaTransfer(
      link: harness.link,
      route: OtaRoute.zeroHop(),
      contract: OtaStartContract(
        imageSize: target.length,
        imageSha256: _sha256Bytes(target),
        targetId: _testTargetId,
        token: 0x22222222, // attacker's guess — not the pending arm's token
      ),
      ops: ops,
      windowSize: 4,
      askTimeout: const Duration(milliseconds: 50),
      maxRetriesPerWindow: 3,
      opSpacing: Duration.zero,
    );
    await expectLater(transfer.run, throwsA(isA<OtaTransferException>()));
    expect(harness.node.state, FakeNodeState.idle);
    expect(harness.node.err, 7);
  });

  test('fromContactPath reverses the route and encodes both lengths', () {
    final route = OtaRoute.fromContactPath(
      outPathLen: 0x02, // 2 hops, 1-byte hashes
      outPath: Uint8List.fromList([0xAA, 0xBB]),
    );
    expect(route.encodedPathLen, 0x02);
    expect(route.path, [0xAA, 0xBB]);
    expect(route.retPath, [0xBB, 0xAA]);
    expect(route.retPathLen, 0x02);

    final two = OtaRoute.fromContactPath(
      outPathLen: 0x43, // 3 hops, 2-byte hashes
      outPath: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
    );
    expect(two.retPath, [5, 6, 3, 4, 1, 2]);
    expect(two.retPathLen, 0x43);

    expect(
      () => OtaRoute.fromContactPath(outPathLen: 0xFF, outPath: Uint8List(0)),
      throwsA(isA<OtaTransferException>()),
    );
  });

  test('cancellation stops the transfer between windows', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(16384, (i) => (i * 7 + 1) & 0xFF));
    final target = _mutate(base, random, edits: 200);
    harness.wire(base: base, target: target);
    final transfer =
        harness.makeTransfer(target: target, base: base, windowSize: 2);
    var progressCalls = 0;
    await expectLater(
      transfer.run(onProgress: (_) {
        progressCalls++;
        if (progressCalls == 1) transfer.cancel();
      }),
      throwsA(isA<OtaTransferException>()),
    );
    expect(transfer.cancelRequested, isTrue);
  });

  test('a lagging node is waited for, not re-broadcast at', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 29 + 3) & 0xFF));
    final target = _mutate(base, random);
    harness.wire(base: base, target: target);
    final transfer = harness.makeTransfer(target: target, base: base);
    // The node takes the window off the air but commits one op per ask, as a
    // flash write that stalls the watermark does on hardware.
    harness.node.commitPerAsk = 1;
    final result = await transfer.run();
    expect(harness.node.state, FakeNodeState.ready);
    // Recovery came from asking again, so nothing was sent twice.
    expect(result.duplicateOps, 0,
        reason: 'a node that is merely behind must not be re-sent ops');
    expect(result.opAmplification, 1.0);
    expect(result.amplification, 1.0);
    expect(result.literalBytesSent, result.uniqueLiteralBytes);
  });

  test('the amplification metric counts re-broadcast bytes', () async {
    final harness = _Harness();
    // Own seed: the file shares one Random, which would make this case depend
    // on test order.
    final seeded = Random(0xA11CE);
    final base = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 17 + 11) & 0xFF));
    final target = _mutate(base, seeded);
    harness.wire(base: base, target: target, dropPercent: 12);
    final transfer = harness.makeTransfer(target: target, base: base);
    final result = await transfer.run();
    expect(harness.node.state, FakeNodeState.ready);
    // Ops really were lost, so recovery had to re-broadcast: the metric must
    // show it rather than reporting a perfect 1.0x.
    expect(result.duplicateOps, greaterThan(0));
    expect(result.opAmplification, greaterThan(1.0));
  });

  test('result labels expose the efficiency numbers', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(1024, (i) => (i * 13 + 5) & 0xFF));
    final target = _mutate(base, Random(0xBEEF));
    harness.wire(base: base, target: target);
    final transfer = harness.makeTransfer(target: target, base: base);
    final result = await transfer.run();
    // A clean link sends every byte once, and the labels say so.
    expect(result.amplification, 1.0);
    expect(result.amplificationLabel, '1.00x');
    expect(result.opAmplification, 1.0);
    expect(result.uniqueOps, transfer.wireOps.frames.length);
    expect(result.uniqueLiteralBytes, transfer.wireOps.uniqueLiteralBytes);
    expect(result.uniqueLiteralBytes, greaterThan(0));
  });

  test('every op frame fits the companion frame for its route', () {
    final image = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 31 + 7) & 0xFF));
    for (final pathBytes in [0, 6, 16]) {
      final route = OtaRoute(
        path: Uint8List(pathBytes),
        encodedPathLen: pathBytes == 0 ? 0 : 0x40 | pathBytes,
        retPath: Uint8List(0),
        retPathLen: 0,
      );
      final transfer = OtaTransfer(
        link: FakeDeviceLink(snr: 6.0, rssi: -70),
        route: route,
        contract: OtaStartContract(
          imageSize: image.length,
          imageSha256: Uint8List(32),
          targetId: 1,
          token: 0x12345678,
        ),
        ops: computeDelta(Uint8List(0), image).ops,
      );
      for (final frame in transfer.wireOps.frames) {
        // command + priority + header + path_len + frame bytes
        final companionFrame = 2 + 1 + 1 + pathBytes + frame.length;
        expect(companionFrame, lessThanOrEqualTo(otaStockCompanionFrameLimit),
            reason: 'op frame too large for a $pathBytes-byte route');
      }
      // The image still transfers whole: chunks cover every byte once.
      final literalBytes = transfer.wireOps.frames
          .where((f) => f[2] == otaOpLiteral)
          .fold<int>(0, (sum, f) => sum + (f[5] | (f[6] << 8)));
      expect(literalBytes, image.length);
    }
  });
}
