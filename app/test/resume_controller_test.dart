import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/resume_controller.dart';
import 'package:meshcore_repeater_manager/services/resume_store.dart';
import 'package:ota_core/ota_core.dart';

import 'support.dart';

class _Probe {
  _Probe() : runningSha = Uint8List(32);

  String? connectionProblem;
  Contact? target = contact('XiaoS3');
  ({bool ok, bool admin}) login = (ok: true, admin: true);
  String? selectionProblem;
  OtaNodeInfo? info;
  OtaStatus? status = nodeStatus(
      state: OtaPhase.staging, size: 1000, offset: 600, shaPrefix: '00');
  int? next = 7;
  OtaNodeStatus? live;
  String? stagedProblem;
  bool stagedChecked = false;
  final Uint8List runningSha;

  ResumePlan plan(
          {String? runningShaHex, int frames = 10, int sessionId = 0}) =>
      ResumePlan(
        createdAt: 1,
        targetPublicKeyHex: contact('XiaoS3').publicKeyHex,
        targetName: 'XiaoS3',
        imageSha256: 'aa',
        imageSize: 1000,
        version: 'v1.18.0-r4',
        targetId: targetIdForEnvironment('Xiao_S3_WIO_repeater_observer'),
        runningSha256: runningShaHex ?? bytesToHex(runningSha),
        frames: List<Uint8List>.filled(frames, Uint8List(2)),
        radioMode: 0,
        radioPreset: null,
        radioDurationMinutes: 10,
        enabledRadio2ForUpdate: false,
        manualRoutePath: '',
        transportKind: 'tcp',
        tcpHost: '127.0.0.1',
        tcpPort: 5000,
        bleDeviceId: null,
        sessionId: sessionId,
      );

  ResumeController controller(ResumePlan plan) {
    return ResumeController(
      plan: plan,
      connect: () async => connectionProblem,
      findContact: (_) => target,
      login: (_, __) async => login,
      restoreSelection: (_) async => selectionProblem,
      nodeInfo: (_) async => info,
      status: (_) async => status,
      nextExpected: (_) async => next,
      nodeStatus: (_) async => live,
      verifyStaged: (_, __) async {
        stagedChecked = true;
        return stagedProblem;
      },
    );
  }
}

OtaNodeStatus liveStatus({
  int sessionId = 7,
  int nextExpected = 7,
  int written = 600,
  int features = otaFeatStagedHash,
}) =>
    OtaNodeStatus(
      wireVersion: otaWireVersion,
      targetId: targetIdForEnvironment('Xiao_S3_WIO_repeater_observer'),
      slotSize: 0x200000,
      maxLiteral: 173,
      features: features,
      runningVersion: 'v1.18.0',
      runningSha256: Uint8List(32),
      sessionId: sessionId,
      state: otaStateStaging,
      error: 0,
      imageSize: 1000,
      written: written,
      nextExpected: nextExpected,
      codecs: otaCodecDeflate,
      extensions: const [],
    );

void main() {
  late _Probe probe;
  late ResumePlan plan;

  setUp(() {
    probe = _Probe();
    plan = probe.plan();
    probe.info = nodeInfo(
      targetId: plan.targetId,
      runningSha256: probe.runningSha,
      runningVersion: 'v1.18.0',
    );
  });

  Future<ResumeDecision> check() => probe.controller(plan).check('password');

  test('a live staging session resumes from the node watermark', () async {
    final decision = await check();
    expect(decision.check, ResumeCheck.ready);
    expect(decision.nextExpected, 7);
    expect(decision.target?.name, 'XiaoS3');
    expect(decision.problem, isNull);
  });

  test('a verified staging only needs the apply', () async {
    probe.status = nodeStatus(
        state: OtaPhase.ready, size: 1000, offset: 1000, shaPrefix: '00');
    final decision = await check();
    expect(decision.check, ResumeCheck.readyToApply);
    expect(decision.nextExpected, 10);
  });

  test('a failed reconnect is reported and keeps the repeater identity',
      () async {
    probe.connectionProblem = 'TCP connect failed';
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, 'TCP connect failed');
    expect(decision.target?.name, 'XiaoS3');
  });

  test('a repeater missing from contacts cannot be resumed', () async {
    probe.target = null;
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('contact list'));
  });

  test('a refused password asks for sign-in again', () async {
    probe.login = (ok: false, admin: false);
    final decision = await check();
    expect(decision.check, ResumeCheck.needsLogin);
    expect(decision.problem, contains('Sign-in was refused'));
  });

  test('a non-admin key asks for the admin password', () async {
    probe.login = (ok: true, admin: false);
    final decision = await check();
    expect(decision.check, ResumeCheck.needsLogin);
    expect(decision.problem, contains('not an admin'));
  });

  test('a missing saved image blocks resume', () async {
    probe.selectionProblem = 'image missing';
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, 'image missing');
  });

  test('no OP_INFO answer blocks resume', () async {
    probe.info = null;
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('OTA handshake'));
  });

  test('a different board blocks resume', () async {
    probe.info = nodeInfo(
        targetId: 0xDEADBEEF,
        runningSha256: probe.runningSha,
        runningVersion: 'v1.18.0');
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('not the repeater'));
  });

  test('a changed running image blocks resume', () async {
    probe.info = nodeInfo(
        targetId: plan.targetId,
        runningSha256: Uint8List.fromList(List.filled(32, 9)),
        runningVersion: 'v1.18.0');
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('firmware changed'));
  });

  test('an empty saved hash skips the running-image check', () async {
    plan = probe.plan(runningShaHex: '');
    final decision = await check();
    expect(decision.check, ResumeCheck.ready);
  });

  test('no ota status answer blocks resume', () async {
    probe.status = null;
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('did not answer'));
  });

  test('a different staged size blocks resume', () async {
    probe.status = nodeStatus(
        state: OtaPhase.staging, size: 999, offset: 600, shaPrefix: '00');
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('different image'));
  });

  test('a staged offset past the image blocks resume', () async {
    probe.status = nodeStatus(
        state: OtaPhase.staging, size: 1000, offset: 1001, shaPrefix: '00');
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('different image'));
  });

  test('an idle node has lost the staged upload', () async {
    probe.status = nodeStatus(
        state: OtaPhase.idle, size: 1000, offset: 0, shaPrefix: '00');
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('no longer holds'));
  });

  test('an errored node has lost the staged upload', () async {
    probe.status = nodeStatus(
        state: OtaPhase.error,
        size: 1000,
        offset: 600,
        shaPrefix: '00',
        err: 5);
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('no longer holds'));
  });

  test('a missing or unusable watermark blocks resume', () async {
    probe.next = null;
    expect((await check()).check, ResumeCheck.unavailable);
    probe.next = 1;
    expect((await check()).check, ResumeCheck.unavailable);
    plan = probe.plan(frames: 3);
    probe.next = 9;
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('upload position'));
  });

  test('structured status supplies the watermark without a separate ask',
      () async {
    probe.live = liveStatus();
    probe.next = null; // the legacy OP_ASK is not consulted at all
    final decision = await check();
    expect(decision.check, ResumeCheck.ready);
    expect(decision.nextExpected, 7);
    expect(probe.stagedChecked, isTrue);
  });

  test('a matching session id confirms the staged bytes survived', () async {
    plan = probe.plan(sessionId: 7);
    probe.live = liveStatus(sessionId: 7);
    expect((await check()).check, ResumeCheck.ready);
  });

  test('a changed session id blocks resume after a repeater reboot', () async {
    plan = probe.plan(sessionId: 7);
    probe.live = liveStatus(sessionId: 9);
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, contains('repeater restarted'));
  });

  test('a staged-prefix mismatch stops before more ops are sent', () async {
    probe.live = liveStatus();
    probe.stagedProblem = 'staged bytes differ from the saved firmware';
    final decision = await check();
    expect(decision.check, ResumeCheck.unavailable);
    expect(decision.problem, probe.stagedProblem);
  });

  test('a node without staged hash skips the read-back check', () async {
    probe.live = liveStatus(features: 0);
    expect((await check()).check, ResumeCheck.ready);
    expect(probe.stagedChecked, isFalse);
  });

  test('structured status absent falls back to the legacy watermark', () async {
    probe.live = null;
    final decision = await check();
    expect(decision.check, ResumeCheck.ready);
    expect(decision.nextExpected, 7);
    expect(probe.stagedChecked, isFalse);
  });
}
