import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

import 'resume_store.dart';

/// What a reconnect found when checking a saved update.
enum ResumeCheck {
  idle,
  checking,
  needsLogin,
  ready,
  readyToApply,
  unavailable,
}

class ResumeDecision {
  const ResumeDecision({
    required this.check,
    this.problem,
    this.target,
    this.nextExpected,
  });

  final ResumeCheck check;
  final String? problem;
  final Contact? target;
  final int? nextExpected;
}

/// Decides whether a saved update can continue, given the live node's answers.
///
/// Kept separate from [AppState] so every branch — including the refusals — is
/// directly testable without a radio. It performs no writes: the only op that
/// changes the node (`OP_START`) was already sent before the crash, and a
/// resume only asks read-only questions.
class ResumeController {
  ResumeController({
    required this.plan,
    required this.connect,
    required this.findContact,
    required this.login,
    required this.restoreSelection,
    required this.nodeInfo,
    required this.status,
    required this.nextExpected,
    this.nodeStatus,
    this.verifyStaged,
  });

  final ResumePlan plan;

  /// Null on success, or a message explaining why reconnecting failed.
  final Future<String?> Function() connect;

  final Contact? Function(String publicKeyHex) findContact;

  /// Whether the login succeeded and whether it carries admin rights.
  final Future<({bool ok, bool admin})> Function(
      Contact target, String password) login;

  /// Load the saved image and radio plan. Null on success, else the reason.
  final Future<String?> Function(ResumePlan plan) restoreSelection;

  final Future<OtaNodeInfo?> Function(Contact target) nodeInfo;
  final Future<OtaStatus?> Function(Contact target) status;
  final Future<int?> Function(Contact target) nextExpected;

  /// The structured status op, when the node implements it. One query yields
  /// the session id and the upload position, so no separate OP_ASK is needed.
  /// Null on a node that predates the op.
  final Future<OtaNodeStatus?> Function(Contact target)? nodeStatus;

  /// Hash the node's staged prefix against the saved image. Null means the
  /// bytes match (or the check is unavailable); otherwise a reason to stop.
  final Future<String?> Function(Contact target, int written)? verifyStaged;

  Future<ResumeDecision> check(String password) async {
    final connectionProblem = await connect();
    if (connectionProblem != null) {
      return ResumeDecision(
          check: ResumeCheck.unavailable,
          problem: connectionProblem,
          target: findContact(plan.targetPublicKeyHex));
    }
    final target = findContact(plan.targetPublicKeyHex);
    if (target == null) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        problem: 'The repeater is not in this companion’s contact list.',
      );
    }
    final result = await login(target, password);
    if (!result.ok) {
      return ResumeDecision(
        check: ResumeCheck.needsLogin,
        target: target,
        problem: 'Sign-in was refused. Check the admin password.',
      );
    }
    if (!result.admin) {
      return ResumeDecision(
        check: ResumeCheck.needsLogin,
        target: target,
        problem:
            'This key is not an admin on the repeater. Enter the admin password.',
      );
    }
    final selectionProblem = await restoreSelection(plan);
    if (selectionProblem != null) {
      return ResumeDecision(
          check: ResumeCheck.unavailable,
          target: target,
          problem: selectionProblem);
    }
    final info = await nodeInfo(target);
    if (info == null || info.targetId != plan.targetId) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'This is not the repeater the update was started on, or it is '
            'running firmware without the OTA handshake.',
      );
    }
    if (plan.runningSha256.isNotEmpty &&
        bytesToHex(info.runningSha256) != plan.runningSha256) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'The repeater’s firmware changed since this update was saved.',
      );
    }
    // The structured report is available on nodes with the new capability
    // API. Its session id turns "did the repeater reboot?" from a guess into a
    // fact, and it carries the upload position so no separate OP_ASK is sent.
    final live = nodeStatus == null ? null : await nodeStatus!(target);
    if (live != null &&
        plan.sessionId != 0 &&
        live.sessionId != plan.sessionId) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'The repeater restarted since the update was saved, so the '
            'uploaded part is gone. Start a new update.',
      );
    }

    final cliStatus = await status(target);
    if (cliStatus == null) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'The repeater did not answer `ota status`.',
      );
    }
    if (cliStatus.size != plan.imageSize || cliStatus.offset > plan.imageSize) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem:
            'The repeater is staging a different image than the saved one.',
      );
    }
    if (cliStatus.state == OtaPhase.ready) {
      return ResumeDecision(
        check: ResumeCheck.readyToApply,
        target: target,
        nextExpected: plan.frames.length,
      );
    }
    if (cliStatus.state != OtaPhase.staging) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'The repeater no longer holds the staged update. The firmware '
            'is still saved here, but the upload must start over.',
      );
    }
    // Before sending more ops, prove the bytes already staged are the prefix
    // of the saved image. A node that kept its session but lost flash contents
    // is otherwise only caught by the SHA gate at OP_END — after the whole
    // remainder has been uploaded.
    if (live != null &&
        live.supports(otaFeatStagedHash) &&
        verifyStaged != null &&
        live.written > 0) {
      final problem = await verifyStaged!(target, live.written);
      if (problem != null) {
        return ResumeDecision(
          check: ResumeCheck.unavailable,
          target: target,
          problem: problem,
        );
      }
    }
    int? next = live?.nextExpected;
    next ??= await nextExpected(target);
    if (next == null || next < 2 || next - 1 > plan.frames.length) {
      return ResumeDecision(
        check: ResumeCheck.unavailable,
        target: target,
        problem: 'The repeater did not report a usable upload position.',
      );
    }
    return ResumeDecision(
      check: ResumeCheck.ready,
      target: target,
      nextExpected: next,
    );
  }
}
