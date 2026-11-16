import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_ota/services/update_flow.dart';
import 'package:ota_core/ota_core.dart';

/// A fake companion with a fork-firmware repeater behind it, speaking real
/// companion frames and the fork's OTA op interpreter. Exercises the app's
/// whole OTA path: login → probe → stage → wire transfer → ready → apply →
/// post-reboot verify. Stateful like the real node, including SHA-gated
/// apply.
class _FakeCompanion {
  _FakeCompanion() {
    _running = _pattern(0x11, 8192);
    _previousImage = Uint8List(0);
  }

  /// The repeater's contact record as known by the companion.
  final Contact target = Contact(
    publicKey: Uint8List.fromList(
        List<int>.generate(32, (i) => (0x30 + i * 3) & 0xFF)),
    name: 'tower-1',
    advType: advTypeRepeater,
  );

  late Uint8List _running;
  Uint8List? _staging;
  String _nodeVersion = 'v1.17.0-filter-aaaaaaaaaaaa';
  String? _previousVersion;
  Uint8List _previousImage = Uint8List(0);

  // arm state (what `ota stage` registers)
  bool _armValid = false;
  int _armSize = 0;
  List<int> _armSha = const [];
  int _armToken = 0;

  // op-interpreter state
  int _expect = 1;
  int _written = 0;
  int _size = 0;
  List<int> _expectedSha = const [];
  bool _ready = false;

  final FakeDeviceLink link = FakeDeviceLink(snr: 6.0, rssi: -70);

  Uint8List get stagedImage => Uint8List.sublistView(_staging!, 0, _written);
  String get nodeVersion => _nodeVersion;

  static Uint8List _pattern(int seed, int length) => Uint8List.fromList(
      List<int>.generate(length, (i) => (i * seed + 17) & 0xFF));

  void debugSetRunning(Uint8List image) => setRunningForTest(image);

  Future<void> boot() async {
    await link.connect();
    link.frameHandler = _onCommandFrame;
    link.txHandler = _onRawPacket;
  }

  void setRunningForTest(Uint8List image) {
    _running = Uint8List.fromList(image);
  }

  void _onCommandFrame(Uint8List frame) {
    if (frame.isEmpty) return;
    switch (frame[0]) {
      case cmdGetContacts:
        _pushContacts();
        break;
      case cmdSendLogin:
        _pushLoginOk();
        break;
      case cmdSendTxtMsg:
        _enqueueCliReply(_decodeCliCommand(frame));
        break;
      case cmdSyncNextMessage:
        _pushNextMessage();
        break;
    }
  }

  // --- companion side ------------------------------------------------------

  void _pushContacts() {
    link.simulatePush(Uint8List.fromList([respCodeContactsStart, 1, 0, 0, 0]));
    link.simulatePush(Uint8List.fromList(
        [respCodeContact, ...target.toCompanionFrameBody()]));
    link.simulatePush(Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
  }

  void _pushLoginOk() {
    // [PUSH_CODE_LOGIN_SUCCESS, is_admin=1, prefix(6), ...]
    link.simulatePush(Uint8List.fromList([
      pushCodeLoginSuccess,
      1,
      ...target.publicKey.sublist(0, 6),
      0,
      0,
      0,
      0,
      7,
      14
    ]));
  }

  String _decodeCliCommand(Uint8List frame) {
    // [cmd, txt_type, attempt, ts(4), prefix(6), text..., 0]
    const textStart = 1 + 1 + 1 + 4 + 6;
    final end = frame.indexOf(0, textStart);
    return String.fromCharCodes(
        end >= 0 ? frame.sublist(textStart, end) : frame.sublist(textStart));
  }

  String? _pendingReply;

  void _enqueueCliReply(String command) {
    _pendingReply = _cliReply(command);
    link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
  }

  void _pushNextMessage() {
    final reply = _pendingReply;
    _pendingReply = null;
    if (reply == null) {
      link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
      return;
    }
    final w = BufferWriter();
    w.writeByte(respCodeContactMsgRecvV3);
    w.writeByte(6); // snr
    w.writeByte(0);
    w.writeByte(0);
    w.writeBytes(target.publicKey.sublist(0, 6));
    w.writeByte(0xFF);
    w.writeByte(txtTypeCliData);
    w.writeUInt32Le(1700000000);
    w.writeBytes([...reply.codeUnits, 0]);
    link.simulatePush(w.toBytes());
  }

  // --- the repeater: ota CLI + op interpreter ------------------------------

  String _runningSha16() => sha256
      .convert(_running)
      .bytes
      .sublist(0, 8)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  String _state() {
    if (_ready) return 'ready';
    if (_written > 0) return 'staging';
    return 'idle';
  }

  String _cliReply(String command) {
    if (command == 'ota status') {
      return 'running=$_nodeVersion sha=${_runningSha16()} state=${_state()} '
          'size=$_size off=$_written err=0';
    }
    if (command == 'version') return '$_nodeVersion (Build: Nov 11 2026)';
    if (command == 'ota abort') {
      _resetStaging();
      return 'OK - aborted';
    }
    if (command.startsWith('ota stage ')) {
      final parts = command.split(' ');
      // ota stage <size> <sha256hex> <ver>
      final size = int.tryParse(parts.length > 2 ? parts[2] : '');
      if (size == null || parts.length < 4) {
        return 'Err - size must be 1..2147483647';
      }
      final shaHex = parts[3];
      if (shaHex.length != 64) return 'Err - sha256 must be 64 hex chars';
      _armValid = true;
      _armSize = size;
      _armSha = _hexToBytes(shaHex);
      _armToken = 0xDEADBEEF;
      return 'OK - staging armed (size=$size) token=deadbeef';
    }
    if (command == 'ota apply') {
      if (!_ready) return 'Err - no verified staging (see ota status)';
      _previousImage = Uint8List.fromList(_running);
      _previousVersion = _nodeVersion;
      _running = Uint8List.fromList(_staging!);
      _nodeVersion = 'v1.18.0-r4-filter-d1ebd2f';
      _resetStaging();
      return 'OK - applied; rebooting';
    }
    if (command == 'ota rollback') {
      if (_previousImage.isNotEmpty) {
        _running = _previousImage;
        _nodeVersion = _previousVersion ?? _nodeVersion;
        _previousImage = Uint8List(0);
        _previousVersion = null;
      }
      _resetStaging();
      return 'OK - rolling back; rebooting';
    }
    return 'Err - unknown command';
  }

  void _resetStaging() {
    _staging = null;
    _written = 0;
    _size = 0;
    _expect = 1;
    _ready = false;
    _armValid = false;
  }

  static List<int> _hexToBytes(String hex) => List<int>.generate(
      hex.length ~/ 2,
      (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));

  Future<bool> _onRawPacket(Uint8List packetBytes, int priority) async {
    final payload = _otaPayload(packetBytes);
    if (payload != null) {
      for (final response in _handleOtaFrame(payload)) {
        final replyPacket = PacketBuilder.createRawCustom(response).writeTo();
        link.simulatePush(Uint8List.fromList([0x88, 24, 0xBA, ...replyPacket]));
      }
    }
    return true; // companion OK'd the write
  }

  Uint8List? _otaPayload(Uint8List packetBytes) {
    final pkt = Packet.readFrom(packetBytes);
    if (pkt == null || pkt.payloadType != payloadTypeRawCustom) return null;
    return Uint8List.fromList(pkt.payload);
  }

  List<Uint8List> _handleOtaFrame(Uint8List frame) {
    final body = unwrapFrame(frame);
    if (body == null) return const [];
    final op = body[2];

    if (op == otaOpAsk) {
      if (!_stagingArmed) return const [];
      return [
        buildOp(otaOpReport, body: [_expect & 0xFF, (_expect >> 8) & 0xFF])
      ];
    }

    if (op == otaOpStart) {
      if (body.length < 5 + 44 || body[3] != 0) return const [];
      final bd = ByteData.sublistView(body, 5);
      final size = bd.getUint32(0, Endian.little);
      final sha = body.sublist(9, 41);
      final targetId = bd.getUint32(36, Endian.little);
      final token = bd.getUint32(40, Endian.big);
      if (targetId != targetIdForEnvironment('Xiao_S3_WIO_repeater')) {
        return const [];
      }
      if (!_armValid ||
          token != _armToken ||
          size != _armSize ||
          !_bytesEqual(sha, _armSha)) {
        return const []; // rejected, silently dropped like the firmware
      }
      _armValid = false;
      _staging = Uint8List(size);
      _written = 0;
      _size = size;
      _expectedSha = List<int>.from(sha);
      _expect = 1;
      _ready = false;
      return const [];
    }

    if (!_stagingArmed) return const [];
    final seq = body[3] | (body[4] << 8);
    if (seq != _expect) return const [];

    if (op == otaOpLiteral) {
      final len = body[5] | (body[6] << 8);
      if (_staging == null) return const [];
      if (body.length < 7 + len || _written + len > _size) return const [];
      _staging!.setRange(_written, _written + len, body.sublist(7, 7 + len));
      _written += len;
      _expect++;
      return const [];
    }
    if (op == otaOpCopy) {
      final bd = ByteData.sublistView(body, 5);
      final baseOffset = bd.getUint32(0, Endian.little);
      final len = bd.getUint16(4, Endian.little);
      if (_staging == null) return const [];
      if (baseOffset + len > _running.length || _written + len > _size) {
        return const [];
      }
      _staging!.setRange(_written, _written + len,
          _running.sublist(baseOffset, baseOffset + len));
      _written += len;
      _expect++;
      return const [];
    }
    if (op == otaOpEnd) {
      if (_staging == null) return const [];
      final digest = sha256.convert(_staging!.sublist(0, _written)).bytes;
      _ready = _bytesEqual(digest, _expectedSha);
      return const [];
    }
    return const [];
  }

  bool get _stagingArmed => _staging != null;

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

void main() {
  late _FakeCompanion fake;
  late UpdateFlow flow;

  setUp(() async {
    fake = _FakeCompanion();
    await fake.boot();
    flow = UpdateFlow(client: CompanionClient(fake.link), link: fake.link);
  });

  test('probe logs in and parses ota status', () async {
    final status = await flow.probe(fake.target, 'hunter2');
    expect(status, isNotNull);
    expect(status!.running, 'v1.17.0-filter-aaaaaaaaaaaa');
    expect(status.state, OtaPhase.idle);
    expect(status.ok, isTrue);
  });

  test('pacing is derived from the radio and never below the floor', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image = Uint8List.fromList(_FakeCompanion._pattern(0x5C, 600));
    fake.setRunningForTest(image);
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    final ops = computeDelta(Uint8List(0), image).ops;
    final sw = Stopwatch()..start();
    // No opSpacing override: the flow asks the link for radio params and paces
    // to a full-size packet's airtime (plus a commit margin), min 250 ms.
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
    );
    sw.stop();
    expect(fake.stagedImage, image);
    // Real pacing applied: the transfer cannot be instant.
    expect(sw.elapsedMilliseconds, greaterThan(200));
  });

  test('full pipeline: stage → transfer → ready → apply → verify', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final baseImage = _FakeCompanion._pattern(0x22, 8192);
    final image = Uint8List.fromList(baseImage);
    for (var i = 0; i < 100; i++) {
      image[(i * 7919) % image.length] ^= 0x5A;
    }
    fake.setRunningForTest(baseImage);

    // Stage through the real CLI path — the reply arms the fake node.
    final stage = await flow.stage(fake.target, image, version: 'v1.18.0-r4');
    expect(stage.token, 0xDEADBEEF);

    final ops = computeDelta(baseImage, image).ops;
    final result = await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: Uint8List.fromList(sha256.convert(image).bytes),
        targetId: targetIdForEnvironment(env),
        token: stage.token,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero, // tests are not paced to a radio
    );
    expect(result.packetsSent, greaterThan(0));
    expect(fake.stagedImage, image);

    final ready = await flow.awaitReady(fake.target);
    expect(ready.state, OtaPhase.ready);

    await flow.apply(fake.target);
    expect(fake.nodeVersion, contains('v1.18.0-r4'));

    final verified =
        await flow.awaitVersion(fake.target, 'hunter2', 'v1.18.0-r4');
    expect(verified, isTrue);
  });

  test('awaitReady throws when the staged image fails the SHA gate', () async {
    const env = 'Xiao_S3_WIO_repeater';
    final image =
        Uint8List.fromList(List<int>.generate(600, (i) => (i * 3 + 7) & 0xFF));

    // Arm with a DIFFERENT image than what the ops carry — the END digest
    // then cannot match, and the node must report not-ready.
    final wrongImage = Uint8List.fromList(List<int>.generate(600, (i) => 0xAA));
    await flow.stage(fake.target, wrongImage, version: 'v1.18.0-r4');

    // Ops carry `image`: staged bytes != wrongImage → SHA mismatch at END.
    final ops = computeDelta(Uint8List(0), image).ops;
    final imageSha = Uint8List.fromList(sha256.convert(wrongImage).bytes);
    await flow.transfer(
      target: fake.target,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: imageSha,
        targetId: targetIdForEnvironment(env),
        token: 0xDEADBEEF,
      ),
      ops: ops,
      route: OtaRoute.zeroHop(),
      windowSize: 4,
      opSpacing: Duration.zero, // tests are not paced to a radio
    );
    expect(() => flow.awaitReady(fake.target),
        throwsA(isA<UpdateFlowException>()));
  });
}
