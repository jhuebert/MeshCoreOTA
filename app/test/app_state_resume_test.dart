import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:meshcore_repeater_manager/app_state.dart';
import 'package:meshcore_repeater_manager/services/resume_controller.dart';
import 'package:meshcore_repeater_manager/services/resume_store.dart';

import 'support.dart';

ResumePlan _plan({
  String imageSha256 = '11',
  int frameCount = 2,
  String targetPublicKeyHex = '00',
  int targetId = 1,
  String runningSha256 = '22',
}) =>
    ResumePlan(
      createdAt: 1,
      targetPublicKeyHex: targetPublicKeyHex,
      targetName: 'XiaoS3',
      imageSha256: imageSha256,
      imageSize: 1000,
      version: 'v1.18.0-r4',
      targetId: targetId,
      runningSha256: runningSha256,
      frames: List<Uint8List>.filled(frameCount, Uint8List(2)),
      radioMode: 0,
      radioPreset: null,
      radioDurationMinutes: 10,
      enabledRadio2ForUpdate: false,
      manualRoutePath: '',
      transportKind: 'tcp',
      tcpHost: '127.0.0.1',
      tcpPort: 5000,
      bleDeviceId: null,
    );

void main() {
  late Directory dir;
  late AppState app;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('app_state_resume_test');
    app = AppState();
    app.resumeStore = ResumeStore(File('${dir.path}/ota_resume.bin'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('checking with no saved update does nothing', () async {
    await app.prepareResume(password: 'pw');
    expect(app.resumeCheck, ResumeCheck.idle);
    expect(app.resumeBusy, isFalse);
  });

  test('the real probe reconnects, signs in and reads the node', () async {
    final image = Uint8List.fromList(List.filled(64, 5));
    final sha = sha256.convert(image);
    final targetId = targetIdForEnvironment('Xiao_S3_WIO_repeater_observer');
    final radio = _FakeRadio(
      target: contact('XiaoS3'),
      running: image,
      targetId: targetId,
    );
    await radio.boot();
    app.tcpLinkFactory = (_, __) => radio.link;
    final lib = FakeLibrary();
    lib.addImage(image,
        env: 'Xiao_S3_WIO_repeater_observer', version: 'v1.18.0-r4');
    app.library = lib;
    app.libraryEntries = await lib.list();
    app.resumePlan = _plan(
      imageSha256: sha.toString(),
      targetPublicKeyHex: radio.target.publicKeyHex,
      targetId: targetId,
      runningSha256: bytesToHex(Uint8List.fromList(sha.bytes)),
      frameCount: 10,
    );

    await app.prepareResume(password: 'pw');

    expect(app.resumeCheck, ResumeCheck.ready);
    expect(app.resumeNextExpected, 7);
    expect(app.target?.name, 'XiaoS3');
    expect(app.selectedImage, image);
  });

  test('the controller decision is applied to AppState', () async {
    final target = contact('XiaoS3');
    app.resumePlan = _plan();
    app.resumeControllerFactory = (plan) => _FakeController(
          ResumeDecision(
              check: ResumeCheck.ready,
              target: target,
              nextExpected: 2,
              problem: null),
        );

    await app.prepareResume(password: 'secret');

    expect(app.resumeCheck, ResumeCheck.ready);
    expect(app.resumeNextExpected, 2);
    expect(app.resumeProblem, isNull);
    expect(app.target?.name, 'XiaoS3');
    expect(app.adminPassword, 'secret');
    expect(app.resumeBusy, isFalse);
  });

  test('a controller failure becomes an unavailable check with a reason',
      () async {
    app.resumePlan = _plan();
    app.resumeControllerFactory = (_) => _ThrowingController();

    await app.prepareResume(password: 'pw');

    expect(app.resumeCheck, ResumeCheck.unavailable);
    expect(app.resumeProblem, isNotNull);
    expect(app.resumeBusy, isFalse);
  });

  test('cancelling clears the saved record even without a connection',
      () async {
    await app.resumeStore!.save(_plan());
    app.resumePlan = _plan();
    app.resumeCheck = ResumeCheck.ready;
    app.updatePhase = UpdatePhase.failed;

    await app.cancelResume();

    expect(app.resumePlan, isNull);
    expect(app.resumeCheck, ResumeCheck.idle);
    expect(app.resumeNextExpected, isNull);
    expect(app.updatePhase, UpdatePhase.idle);
    expect(await File('${dir.path}/ota_resume.bin').exists(), isFalse);
  });

  test('restoring a saved selection loads the image and radio plan', () async {
    final image = Uint8List.fromList(List.filled(64, 3));
    final lib = FakeLibrary();
    lib.addImage(image, env: 'Xiao_S3_WIO_repeater', version: 'v1.18.0-r4');
    app.library = lib;
    app.libraryEntries = await lib.list();

    final problem = await app.restoreResumeSelection(
        _plan(imageSha256: sha256.convert(image).toString()));

    expect(problem, isNull);
    expect(app.selectedImage, image);
    expect(app.manualRoutePath, isEmpty);
  });

  test('a missing saved image is reported instead of guessed', () async {
    app.library = FakeLibrary();
    app.libraryEntries = const [];
    final problem = await app.restoreResumeSelection(_plan());
    expect(problem, contains('no longer on this device'));
  });

  test('saving a resume record writes the op frames', () async {
    await app.saveResumePlan(
      t: contact('XiaoS3'),
      image: Uint8List(64),
      targetId: 1,
      frames: <Uint8List>[Uint8List(2)],
      version: 'v1.18.0-r4',
    );

    expect(app.resumePlan, isNotNull);
    final loaded = await app.resumeStore!.load();
    expect(loaded?.frames.length, 1);
    expect(loaded?.targetName, 'XiaoS3');
    expect(await File('${dir.path}/ota_resume.bin').exists(), isTrue);
  });

  test('pausing keeps the plan and the last known transfer position', () async {
    app.updatePhase = UpdatePhase.transferring;

    await app.pauseTransfer(
      t: contact('XiaoS3'),
      image: Uint8List(64),
      targetId: 1,
      frames: <Uint8List>[Uint8List(2)],
      version: 'v1.18.0-r4',
      nextExpected: 42,
    );

    expect(app.updatePhase, UpdatePhase.idle);
    expect(app.resumePlan, isNotNull);
    expect(app.resumePlan!.nextExpected, 42);
    final loaded = await app.resumeStore!.load();
    expect(loaded?.nextExpected, 42);
    expect(loaded?.frames.length, 1);
  });

  test('finishing a completed upload moves to the apply phase', () {
    app.finishResumeApply();
    expect(app.updatePhase, UpdatePhase.readyToApply);
  });

  test('resuming without a plan fails fast', () async {
    await expectLater(app.resumeTransfer(), throwsStateError);
  });
}

class _FakeController extends ResumeController {
  _FakeController(this.decision)
      : super(
            plan: _plan(),
            connect: () async => null,
            findContact: (_) => null,
            login: (_, __) async => (ok: true, admin: true),
            restoreSelection: (_) async => null,
            nodeInfo: (_) async => null,
            status: (_) async => null,
            nextExpected: (_) async => null);

  final ResumeDecision decision;

  @override
  Future<ResumeDecision> check(String password) async => decision;
}

class _ThrowingController extends ResumeController {
  _ThrowingController()
      : super(
            plan: _plan(),
            connect: () async => null,
            findContact: (_) => null,
            login: (_, __) async => (ok: true, admin: true),
            restoreSelection: (_) async => null,
            nodeInfo: (_) async => null,
            status: (_) async => null,
            nextExpected: (_) async => null);

  @override
  Future<ResumeDecision> check(String password) async =>
      throw StateError('probe broke');
}

/// Minimal companion + repeater that answers exactly what the recovery probe
/// asks: self info, contacts, admin login, OP_INFO, `ota status` and OP_ASK.
class _FakeRadio {
  _FakeRadio({
    required this.target,
    required this.running,
    required this.targetId,
  });

  final Contact target;
  final Uint8List running;
  final int targetId;
  final FakeDeviceLink link = FakeDeviceLink(snr: 6.0, rssi: -70);

  String? _pendingReply;

  Future<void> boot() async {
    await link.connect();
    link.frameHandler = (frame) {
      if (frame.isEmpty) return;
      switch (frame[0]) {
        case cmdAppStart:
          _pushSelfInfo();
        case cmdGetContacts:
          _pushContacts();
        case cmdSendLogin:
          _pushLoginOk();
        case cmdSendTxtMsg:
          _enqueueCli(frame);
        case cmdSyncNextMessage:
          _pushNextMessage();
      }
    };
    link.binaryRequestHandler = (contact, req, tag) async {
      if (req.length < 2 || req[0] != reqTypeOta) return;
      final frame = unwrapFrame(Uint8List.fromList(req.sublist(
          2, 2 + (req[1] > req.length - 2 ? req.length - 2 : req[1]))));
      if (frame == null) return;
      final op = frame[2];
      Uint8List? report;
      if (op == otaOpInfo) report = _info();
      if (op == otaOpAsk) {
        report = buildOp(otaOpReport, body: [7, 0]);
      }
      if (report == null) return;
      link.simulatePush(Uint8List.fromList([
        pushCodeBinaryResponse,
        0,
        ...contact.publicKey.sublist(0, 6),
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...report,
      ]));
    };
  }

  void _pushSelfInfo() {
    final w = BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(advTypeRepeater)
      ..writeByte(20)
      ..writeByte(22)
      ..writeBytes(target.publicKey)
      ..writeInt32Le(0)
      ..writeInt32Le(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeUInt32Le(926000)
      ..writeUInt32Le(500000)
      ..writeByte(7)
      ..writeByte(5)
      ..writeCString('bench-companion', 32);
    link.simulatePush(w.toBytes());
  }

  void _pushContacts() {
    link.simulatePush(Uint8List.fromList([respCodeContactsStart, 1, 0, 0, 0]));
    link.simulatePush(Uint8List.fromList(
        [respCodeContact, ...target.toCompanionFrameBody()]));
    link.simulatePush(Uint8List.fromList([respCodeEndOfContacts, 0, 0, 0, 0]));
  }

  void _pushLoginOk() {
    link.simulatePush(Uint8List.fromList([
      pushCodeLoginSuccess,
      1,
      ...target.publicKey.sublist(0, 6),
      0,
      0,
      0,
      0,
      7,
      14,
    ]));
  }

  Uint8List _info() {
    final sha = sha256.convert(running).bytes;
    final ver = Uint8List(32);
    final name = utf8.encode('v1.18.0');
    ver.setRange(0, name.length, name);
    return buildOp(otaOpInfoReport, body: [
      otaWireVersion,
      ..._le32(targetId),
      ..._le32(0x200000),
      ..._le16(173),
      ..._le32(otaFeatDelta | otaFeatApply),
      ...ver,
      ...sha,
    ]);
  }

  void _enqueueCli(Uint8List frame) {
    const start = 1 + 1 + 1 + 4 + 6;
    final end = frame.indexOf(0, start);
    final text = String.fromCharCodes(
        end >= 0 ? frame.sublist(start, end) : frame.sublist(start));
    _pendingReply = text == 'ota status'
        ? 'running=v1.18.0 sha=0000000000000000 state=staging '
            'size=1000 off=600 err=0'
        : 'OK';
    link.simulatePush(Uint8List.fromList([pushCodeMsgWaiting]));
  }

  void _pushNextMessage() {
    final reply = _pendingReply;
    _pendingReply = null;
    if (reply == null) {
      link.simulatePush(Uint8List.fromList([respCodeNoMoreMessages]));
      return;
    }
    final w = BufferWriter()
      ..writeByte(respCodeContactMsgRecvV3)
      ..writeByte(6)
      ..writeByte(0)
      ..writeByte(0)
      ..writeBytes(target.publicKey.sublist(0, 6))
      ..writeByte(0xFF)
      ..writeByte(txtTypeCliData)
      ..writeUInt32Le(1700000000)
      ..writeBytes([...utf8.encode(reply), 0]);
    link.simulatePush(w.toBytes());
  }

  static List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
}
