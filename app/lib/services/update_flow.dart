import 'dart:async';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

/// One completed stage of the update, for progress display.
enum FlowStep {
  probing,
  staging,
  transferring,
  verifying,
  applying,
  verifyingApply
}

/// Errors from the update flow, with the device's own reply when there is one.
class UpdateFlowException implements Exception {
  UpdateFlowException(this.message, {this.deviceReply});

  final String message;

  /// The `Err - ...` line the device produced, when applicable.
  final String? deviceReply;

  @override
  String toString() =>
      deviceReply == null ? message : '$message ($deviceReply)';
}

/// Orchestrates one over-the-air update: login → probe → stage → transfer →
/// apply → post-reboot verification. App-side "all intelligence": it picks
/// images and transfer parameters; the node only applies ops and SHA-256s.
///
/// The repeater never reboots until the operator confirms the staged image
/// passed its SHA gate (`ota apply`), and a failed health check flips back
/// automatically in the fork firmware.
class UpdateFlow {
  UpdateFlow({required this.client, required this.link});

  final CompanionClient client;
  final RadioLink link;

  /// Login (admin) and read `ota status`. Throws with the device's reply on
  /// failure; returns null when the node rejected admin (or the firmware
  /// does not speak the ota CLI at all — e.g. pre-fork stock firmware).
  Future<OtaStatus?> probe(Contact target, String password) async {
    final login = await client.login(target, password);
    if (!login.ok) {
      throw UpdateFlowException('login rejected');
    }
    if (!login.isAdmin) {
      throw UpdateFlowException(
          'logged in, but not as admin — OTA needs admin');
    }
    final reply = await _cli(target, 'ota status');
    return OtaStatus.parse(reply);
  }

  /// Whether the node runs an OTA-capable fork firmware.
  Future<bool> supportsOta(Contact target, String password) async =>
      await probe(target, password) != null;

  /// Arm the node with the exact image to stage. Returns the parsed arm
  /// contract (size + token) to hand to the transfer.
  Future<OtaStageReply> stage(
    Contact target,
    Uint8List image, {
    required String version,
  }) async {
    final sha = sha256.convert(image).toString();
    final reply = await _cli(target, 'ota stage ${image.length} $sha $version');
    final parsed = parseStageReply(reply);
    if (parsed == null) {
      throw UpdateFlowException('staging was refused', deviceReply: reply);
    }
    return parsed;
  }

  /// Run the op-stream transfer against an armed node.
  Future<TransferResult> transfer({
    required Contact target,
    required OtaStartContract contract,
    required List<DeltaOp> ops,
    required OtaRoute route,
    void Function(TransferProgress)? onProgress,
    int windowSize = 12,
    bool Function()? shouldCancel,
  }) async {
    final engine = OtaTransfer(
      link: link,
      route: route,
      contract: contract,
      ops: ops,
      windowSize: windowSize,
      askTimeout: const Duration(seconds: 10),
      maxRetriesPerWindow: 12,
      opSpacing: const Duration(milliseconds: 20),
      shouldCancel: shouldCancel,
    );
    final result = await engine.run(onProgress: onProgress);
    return result;
  }

  /// After the transfer, read `ota status` and require state=ready.
  Future<OtaStatus> awaitReady(Contact target) async {
    final reply = await _cli(target, 'ota status');
    final status = OtaStatus.parse(reply);
    if (status == null) {
      throw UpdateFlowException('unparseable ota status', deviceReply: reply);
    }
    if (status.state != OtaPhase.ready) {
      throw UpdateFlowException(
        'the staged image did not pass verification (${otaErrLabel(status.err)})',
        deviceReply: reply,
      );
    }
    return status;
  }

  /// `ota apply` — boot the verified image. The node reboots; the app link
  /// to the companion is unaffected.
  Future<void> apply(Contact target) async {
    final reply = await _cli(target, 'ota apply');
    if (!isApplyReply(reply)) {
      throw UpdateFlowException('apply refused', deviceReply: reply);
    }
  }

  /// Cancel a staged update and scrape the staging slot.
  Future<void> abort(Contact target) => _cli(target, 'ota abort');

  /// Roll back to the previous partition. The node reboots.
  Future<void> rollback(Contact target) async {
    final reply = await _cli(target, 'ota rollback');
    if (!isRollbackReply(reply)) {
      throw UpdateFlowException('rollback refused', deviceReply: reply);
    }
  }

  /// Drop the armed staging state on the node and leave it idle.
  Future<void> abortQuietly(Contact target) async {
    try {
      await abort(target);
    } catch (_) {}
  }

  /// After an apply/rollback reboot, re-login and poll `version` until it
  /// matches [expectedVersion] (substring match — device versions carry the
  /// build stamp, e.g. `v1.18.0-r4-filter-<sha>`) or the timeout expires.
  ///
  /// Returns true when the new firmware answered. False means the node is
  /// still on the old partition — either the boot health check flipped it
  /// back or the image is broken; the UI says so honestly.
  Future<bool> awaitVersion(
    Contact target,
    String password,
    String expectedVersion, {
    Duration timeout = const Duration(seconds: 120),
    Duration interval = const Duration(seconds: 3),
    void Function()? onTick,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      onTick?.call();
      try {
        // The rebooted node forgets the login; sign back in before asking.
        final login = await client.login(target, password);
        if (login.ok) {
          final v = (await client.remoteCli(target, 'version')).trim();
          if (v.contains(expectedVersion)) return true;
        }
      } catch (_) {
        // Still booting — keep polling.
      }
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// The version string an update verifies against: `v1.18.0-r4`-ish. The
  /// device reply carries the build stamp suffix; substring match is exact
  /// enough for that.
  static String expectedVersionOf(String assetVersion) => assetVersion;

  Future<String> _cli(Contact target, String command) =>
      client.remoteCli(target, command);
}

/// Decode the version the node reports, `vX.Y.Z...` from the raw reply line.
String? parseVersionReply(String reply) {
  final match = RegExp(r'v?\d+\.\d+\.\d+\S*').firstMatch(reply);
  return match?.group(0);
}
