import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_ota/services/resume_controller.dart';
import 'package:meshcore_ota/services/resume_store.dart';
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
  final Uint8List runningSha;

  ResumePlan plan({String? runningShaHex, int frames = 10}) => ResumePlan(
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
    );
  }
}

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
}
