import 'dart:async';
import 'dart:io';
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

  final _lzParts = <int>[];
  int _lzOrig = 0;

  List<Uint8List> handlePacket(Uint8List frame) {
    final body = unwrapFrame(frame);
    if (body == null) {
      return const [];
    }
    final op = body[2];

    if (op == otaOpAsk) {
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
    if (seq != _received) {
      return const []; // strictly in order; everything else is dropped
    }

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

    if (op == otaOpLiteralZ) {
      final orig = body[5] | (body[6] << 8) | (body[7] << 16) | (body[8] << 24);
      final flags = body[11];
      if ((flags & otaLzStart) != 0) {
        _lzParts.clear();
        _lzOrig = orig;
      }
      _lzParts.addAll(body.sublist(12));
      _received++;
      if ((flags & otaLzEnd) != 0) {
        final plain = ZLibCodec(raw: true).decode(_lzParts);
        if (plain.length != _lzOrig || _written + _lzOrig > _size) {
          err = 9;
          state = FakeNodeState.error;
          return const [];
        }
        _slot.setRange(_written, _written + plain.length, plain);
        _written += plain.length;
        _lzParts.clear();
      }
      return const [];
    }

    if (op == otaOpEnd) {
      final digest = sha256.convert(stagedImage).bytes;
      if (_bytesEqual(digest, _expectedSha)) {
        state = FakeNodeState.ready;
        // The firmware advances next_expected after every op that did not
        // error, OP_END included (`if (_state != State::Error) _expect++;`).
        // OP_END is not one of the ops the app counts, so the watermark ends
        // up one past the op count.
        _received++;
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

/// Ask the node for its watermark over a binary request, as a reconnecting
/// client would, and return it once the node answers. Null on no answer.
Future<int?> _askOnce(_Harness harness) async {
  int? staged;
  int? tag;
  final completer = Completer<int?>();
  late StreamSubscription<Uint8List> sub;
  sub = harness.link.pushes.listen((frame) {
    if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return;
    final report = parseBinaryResponse(frame,
        contactPubKey: targetContact.publicKey, askTag: tag);
    if (report != null && !completer.isCompleted) {
      staged = report.nextExpected;
      completer.complete(staged);
    }
  });
  try {
    final sent = await harness.link.sendBinaryRequest(
        targetContact, [reqTypeOta, buildAsk().length, ...buildAsk()]);
    tag = sent.tag;
    return await completer.future.timeout(const Duration(seconds: 1));
  } catch (_) {
    return staged;
  } finally {
    await sub.cancel();
  }
}

/// The target node's contact. The fake does not route by key — the prefix
/// exists so the transfer's pubkey-prefix filter on pushes has something
/// stable to match.
final Contact targetContact = Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  name: 'XiaoS3',
  advType: advTypeRepeater,
  outPathLen: 0,
);

/// `PUSH_CODE_BINARY_RESPONSE` as the companion emits it: code, reserved,
/// truncated sender pubkey, tag, then the response payload (the OP_REPORT
/// frame).
Uint8List binaryResponsePush(Contact contact, int tag, Uint8List report) =>
    Uint8List.fromList([
      pushCodeBinaryResponse,
      0,
      ...contact.publicKey.sublist(0, 6),
      tag & 0xFF,
      (tag >> 8) & 0xFF,
      (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF,
      ...report,
    ]);

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
    link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.length >= 2 && reqData[0] == reqTypeOta) {
        final flen = reqData[1];
        if (reqData.length < 2 + flen) return;
        final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
        for (final response in node.handlePacket(frame)) {
          link.simulatePush(binaryResponsePush(contact, tag, response));
        }
      }
    };
    final ops = computeDelta(base, target).ops;
    return OtaTransfer(
      link: link,
      contact: targetContact,
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

  test('progress never passes 100% once OP_END bumps the watermark', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 31 + 7) & 0xFF));
    final target = _mutate(base, random, edits: 400);
    harness.wire(base: base, target: target);
    final transfer = harness.makeTransfer(target: target, base: base);
    final progress = <TransferProgress>[];
    await transfer.run(onProgress: progress.add);

    // The node reports next_expected one past the op count after OP_END; the
    // app counts only the real ops, so the reported figure must be clamped.
    expect(harness.node.nextExpected, greaterThan(progress.last.opsTotal));
    for (final p in progress) {
      expect(p.fraction, isNotNull);
      expect(p.fraction, inInclusiveRange(0.0, 1.0));
      expect(p.opsApplied, inInclusiveRange(0, p.opsTotal));
    }
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
    harness.link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.length >= 2 && reqData[0] == reqTypeOta) {
        final flen = reqData[1];
        if (reqData.length < 2 + flen) return;
        final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
        for (final response in harness.node.handlePacket(frame)) {
          harness.link.simulatePush(binaryResponsePush(contact, tag, response));
        }
      }
    };
    final ops = computeDelta(base, target).ops;
    final transfer = OtaTransfer(
      link: harness.link,
      contact: targetContact,
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

  test('parsePathList accepts a comma-separated 2-byte path', () {
    final route = OtaRoute.parsePathList('c0ff, c0c0');
    expect(route.encodedPathLen, 0x42);
    expect(route.path, [0xC0, 0xFF, 0xC0, 0xC0]);
    expect(route.manual, isTrue);
    expect(OtaRoute.parsePathList(' ').path, isEmpty);
    expect(() => OtaRoute.parsePathList('c0ff,00'),
        throwsA(isA<OtaTransferException>()));
    expect(() => OtaRoute.parsePathList('gg'),
        throwsA(isA<OtaTransferException>()));
  });

  test('parsePathList treats meshcli "0" as a manual zero hop', () {
    final route = OtaRoute.parsePathList('0');
    expect(route.path, isEmpty);
    expect(route.encodedPathLen, 0);
    expect(route.manual, isTrue);
  });

  test('fromContactPath keeps the contact path and encodes the length', () {
    final route = OtaRoute.fromContactPath(
      outPathLen: 0x02, // 2 hops, 1-byte hashes
      outPath: Uint8List.fromList([0xAA, 0xBB]),
    );
    expect(route.encodedPathLen, 0x02);
    expect(route.path, [0xAA, 0xBB]);
    expect(route.manual, isFalse);

    final two = OtaRoute.fromContactPath(
      outPathLen: 0x43, // 3 hops, 2-byte hashes
      outPath: Uint8List.fromList([1, 2, 3, 4, 5, 6]),
    );
    expect(two.path, [1, 2, 3, 4, 5, 6]);
    expect(two.encodedPathLen, 0x43);

    expect(
      () => OtaRoute.fromContactPath(outPathLen: 0xFF, outPath: Uint8List(0)),
      throwsA(isA<OtaTransferException>()),
    );
  });

  test('route parsing covers the remaining error branches', () {
    expect(
        () => OtaRoute.parsePathList('c0ff,aa'), // mixed hop sizes
        throwsA(isA<OtaTransferException>()));
    expect(
        () => OtaRoute.parsePathList('abc'), // odd length
        throwsA(isA<OtaTransferException>()));
    expect(() => OtaRoute.parsePathList('gg'),
        throwsA(isA<OtaTransferException>()));
    expect(
        () => OtaRoute.parsePathList('001122334455'), // 6-byte hop: too big
        throwsA(isA<OtaTransferException>()));
    expect(
        () => OtaRoute.parsePathList('c0ff,gg'), // bad char past the first hop
        throwsA(isA<OtaTransferException>()));
    final twoHops = List.filled(22, 'aabbcc').join(','); // 66 bytes of path
    expect(
        () => OtaRoute.parsePathList(twoHops), // exceeds MAX_PATH_SIZE
        throwsA(isA<OtaTransferException>()));
    final tooMany = List.filled(64, 'aa').join(','); // 64 hops
    expect(() => OtaRoute.parsePathList(tooMany),
        throwsA(isA<OtaTransferException>()));
    expect(OtaTransferException('why').toString(), 'OtaTransferException: why');
    expect(
      () => OtaRoute.fromContactPath(
          outPathLen: 0x42, outPath: Uint8List.fromList([0xAA])), // wants 4
      throwsA(isA<OtaTransferException>()),
    );
  });

  test('completeNextExpected counts every op frame', () {
    final ops = computeDelta(Uint8List(0), Uint8List.fromList([1, 2, 3])).ops;
    final wire = wireOpsFor(ops);
    expect(wire.completeNextExpected, wire.frames.length);
  });

  test('a node that acknowledges but never commits fails the window', () async {
    final harness = _Harness();
    final base = Uint8List(0);
    final target = Uint8List.fromList(List<int>.generate(24, (i) => i));
    harness.wire(base: base, target: target);
    harness.node.commitPerAsk = 0; // applies the ops, watermark never moves
    harness.link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.length >= 2 && reqData[0] == reqTypeOta) {
        final flen = reqData[1];
        if (reqData.length < 2 + flen) return;
        final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
        for (final response in harness.node.handlePacket(frame)) {
          harness.link.simulatePush(binaryResponsePush(contact, tag, response));
        }
      }
    };
    harness.node.arm(
      size: target.length,
      sha256: _sha256Bytes(target),
      token: 0xBADC0FFE,
    );
    final transfer = OtaTransfer(
      link: harness.link,
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: target.length,
        imageSha256: _sha256Bytes(target),
        targetId: _testTargetId,
        token: 0xBADC0FFE,
      ),
      ops: computeDelta(base, target).ops,
      windowSize: 2,
      askTimeout: const Duration(milliseconds: 50),
      maxRetriesPerWindow: 8,
      maxResendRounds: 2,
      opSpacing: Duration.zero,
      askSettle: Duration.zero,
    );
    await expectLater(
      transfer.run(),
      throwsA(isA<OtaTransferException>()
          .having((e) => e.message, 'message', contains('stalled'))),
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

  test('a dropped link resumes from the node next_expected', () async {
    final harness = _Harness();
    final base = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 23 + 9) & 0xFF));
    final target = _mutate(base, Random(0x5EED));
    harness.wire(base: base, target: target);
    harness.node.arm(
      size: target.length,
      sha256: _sha256Bytes(target),
      token: 0xBADC0FFE,
    );
    harness.link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.length >= 2 && reqData[0] == reqTypeOta) {
        final flen = reqData[1];
        if (reqData.length < 2 + flen) return;
        final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
        for (final response in harness.node.handlePacket(frame)) {
          harness.link.simulatePush(binaryResponsePush(contact, tag, response));
        }
      }
    };

    // Drop the link after a couple of windows: the node keeps what it got.
    var sent = 0;
    final partial = OtaTransfer(
      link: harness.link,
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: target.length,
        imageSha256: _sha256Bytes(target),
        targetId: _testTargetId,
        token: 0xBADC0FFE,
      ),
      ops: computeDelta(base, target).ops,
      windowSize: 2,
      askTimeout: const Duration(milliseconds: 200),
      maxRetriesPerWindow: 8,
      opSpacing: Duration.zero,
      askSettle: Duration.zero,
      shouldCancel: () => ++sent > 3,
    );
    var interrupted = false;
    try {
      await partial.run();
    } on OtaTransferException {
      interrupted = true;
    }
    expect(interrupted, isTrue);
    // The node commits on an ask, so ask once to learn where it actually is —
    // exactly what a reconnecting client must do.
    final staged = await _askOnce(harness);
    expect(staged, isNotNull);
    expect(staged!, greaterThan(1)); // the node kept the ops it applied

    // A resumed engine must not re-arm, and must finish from where it stopped.
    final resumed = OtaTransfer(
      link: harness.link,
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: target.length,
        imageSha256: _sha256Bytes(target),
        targetId: _testTargetId,
        token: 0xBADC0FFE,
      ),
      ops: computeDelta(base, target).ops,
      windowSize: 2,
      askTimeout: const Duration(milliseconds: 200),
      maxRetriesPerWindow: 32,
      opSpacing: Duration.zero,
      askSettle: Duration.zero,
      resumeFrom: staged,
    );
    final result = await resumed.run();
    expect(harness.node.stagedImage, target);
    expect(result.uniqueOps, greaterThan(0));
    expect(result.amplification, 1.0);
    expect(result.opAmplification, 1.0);
    // The arm was consumed by the first attempt: nothing re-armed it.
    expect(harness.node.asks, greaterThan(0));
  });

  test('every op frame fits a stock companion frame', () {
    final image = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 31 + 7) & 0xFF));
    final transfer = OtaTransfer(
      link: FakeDeviceLink(snr: 6.0, rssi: -70),
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List(32),
        targetId: 1,
        token: 0x12345678,
      ),
      ops: computeDelta(Uint8List(0), image).ops,
    );
    for (final frame in transfer.wireOps.frames) {
      // command + pubkey(32) + REQ_TYPE_OTA + the op frame
      final companionFrame = 1 + 32 + 1 + frame.length;
      expect(companionFrame, lessThanOrEqualTo(otaStockCompanionFrameLimit),
          reason: 'op frame too large for a stock companion');
    }
    // The image still transfers whole: chunks cover every byte once.
    final literalBytes = transfer.wireOps.frames
        .where((f) => f[2] == otaOpLiteral)
        .fold<int>(0, (sum, f) => sum + (f[5] | (f[6] << 8)));
    expect(literalBytes, image.length);
  });

  test('compressed literals are chunked and count as their original bytes', () {
    final compressed = Uint8List.fromList(List<int>.generate(260, (i) => i));
    final wire = wireOpsFor([
      CompressedLiteralOp(compressed, 4096),
    ], literalChunk: otaLiteralChunkForBinaryReq());
    final frames = wire.frames;
    expect(frames.length, 4); // three 120/120/20-byte chunks plus OP_END
    expect(frames.first[2], otaOpLiteralZ);
    expect(frames.first[11] & otaLzStart, otaLzStart);
    expect(frames[2][11] & otaLzEnd, otaLzEnd);
    expect(wire.uniqueLiteralBytes, 4096);
    for (final frame in frames) {
      expect(1 + 32 + 1 + frame.length,
          lessThanOrEqualTo(otaStockCompanionFrameLimit));
    }
  });

  test('resume accounting counts a compressed stream once', () {
    final image = Uint8List.fromList(List<int>.filled(4096, 0x5A));
    final gz = GZipCodec(level: 9).encode(image);
    final raw = Uint8List.fromList(gz.sublist(10, gz.length - 8));
    final transfer = OtaTransfer(
      link: FakeDeviceLink(snr: 6, rssi: -70),
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: _sha256Bytes(image),
        targetId: _testTargetId,
        token: 1,
      ),
      ops: [CompressedLiteralOp(raw, image.length)],
      resumeFrom: 2,
    );
    expect(transfer.literalBytesSent, image.length);
  });

  test('a compressed literal stream transfers end to end', () async {
    final image = Uint8List.fromList(List<int>.filled(4096, 0x5A));
    final h = _Harness()..wire(base: Uint8List(0), target: image);
    h.node.arm(
        size: image.length, sha256: _sha256Bytes(image), token: 0x12345678);
    h.link.binaryRequestHandler = (contact, reqData, tag) async {
      if (reqData.length >= 2 && reqData[0] == reqTypeOta) {
        final flen = reqData[1];
        if (reqData.length < 2 + flen) return;
        final frame = Uint8List.fromList(reqData.sublist(2, 2 + flen));
        for (final response in h.node.handlePacket(frame)) {
          h.link.simulatePush(binaryResponsePush(contact, tag, response));
        }
      }
    };
    final gz = GZipCodec(level: 9).encode(image);
    final raw = Uint8List.fromList(gz.sublist(10, gz.length - 8));
    final transfer = OtaTransfer(
      link: h.link,
      contact: targetContact,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: _sha256Bytes(image),
        targetId: _testTargetId,
        token: 0x12345678,
      ),
      ops: [CompressedLiteralOp(raw, image.length)],
      windowSize: 8,
      askTimeout: const Duration(milliseconds: 200),
      opSpacing: Duration.zero,
      askSettle: Duration.zero,
    );
    final result = await transfer.run();
    expect(h.node.state, FakeNodeState.ready);
    expect(h.node.stagedImage, image);
    expect(result.literalBytesSent, image.length);
  });
}
