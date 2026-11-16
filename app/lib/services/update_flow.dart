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
  ///
  /// The ops ride inside binary requests (`CMD_SEND_BINARY_REQ`): the
  /// companion encrypts them as ordinary REQ datagrams and routes them to
  /// [target] using its stored contact record. A hand-built [route] (the
  /// review screen's path override) has no per-packet field to ride, so it is
  /// pushed into the companion as the contact's path first — like `change_path`
  /// in meshcli — and takes effect for this and later sessions until the
  /// companion's record is changed again.
  Future<TransferResult> transfer({
    required Contact target,
    required OtaStartContract contract,
    required List<DeltaOp> ops,
    required OtaRoute route,
    void Function(TransferProgress)? onProgress,
    int windowSize = 12,
    // Overrides the airtime-derived pacing (tests, or a caller that already
    // knows better).
    Duration? opSpacing,
    bool Function()? shouldCancel,
  }) async {
    if (route.manual) {
      try {
        await link.setContactPath(target,
            path: route.path, encodedPathLen: route.encodedPathLen);
      } catch (e) {
        throw UpdateFlowException(
            'could not set the manual path on the companion: $e');
      }
    }
    final spacing = opSpacing ?? await _pacing();
    final engine = OtaTransfer(
      link: link,
      contact: target,
      contract: contract,
      ops: ops,
      windowSize: windowSize,
      askTimeout: const Duration(seconds: 10),
      maxRetriesPerWindow: 12,
      // Pace to the radio, not to the companion's queue. Sending ops faster
      // than the node can commit them provokes re-sends that cost more than
      // the delay saved: on hardware, 100 ms spacing needed 3.8x the ops over
      // 45 s, while 400 ms needed 1.24x over 27 s. One maximum-size packet of
      // airtime, plus a margin for the node's flash commit, is the floor.
      opSpacing: spacing,
      // Let the tail of a window finish transmitting and committing before
      // asking: a premature ask reports a lower next_expected and invites a
      // pointless re-send of ops the node already has.
      askSettle: const Duration(milliseconds: 250),
      shouldCancel: shouldCancel,
    );
    final result = await engine.run(onProgress: onProgress);
    return result;
  }

  /// Delay between queued ops, derived from the radio's airtime.
  ///
  /// A full-size op frame occupies the channel for its whole airtime, and the
  /// node then commits it to flash. Queueing faster than that merely builds a
  /// backlog of ops the node has not written yet, which the window report then
  /// reads as "missing" — so every window gets re-broadcast. Falls back to a
  /// safe constant when the radio parameters are unavailable.
  Future<Duration> _pacing() async {
    const fallback = Duration(milliseconds: 250);
    try {
      final p = await link.radioParams();
      final airtime = loraTimeOnAirMicros(
        payloadBytes: otaMaxPayload,
        spreadingFactor: p.spreadingFactor,
        bandwidthHz: p.bandwidthHz,
        codingRate: p.codingRate,
      );
      final us = (airtime * 1.5).round() + 60000; // airtime + commit margin
      final candidate = Duration(microseconds: us);
      return candidate > fallback ? candidate : fallback;
    } catch (_) {
      return fallback;
    }
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
    String reply;
    try {
      reply = await _cli(target, 'ota apply');
    } catch (_) {
      // A successful apply reboots the repeater immediately. On a busy mesh,
      // the reboot can race the encrypted CLI reply: hardware testing observed
      // the node running the new image even though this reply timed out. Treat
      // transport loss as an unknown outcome; applyAndVerify() decides by
      // re-logging in and checking the version. A textual Err reply remains a
      // definite refusal.
      return;
    }
    if (!isApplyReply(reply)) {
      throw UpdateFlowException('apply refused', deviceReply: reply);
    }
  }

  /// Cancel a staged update and scrape the staging slot.
  Future<void> abort(Contact target) => _cli(target, 'ota abort');

  /// Roll back to the previous partition. The node reboots.
  Future<void> rollback(Contact target) async {
    String reply;
    try {
      reply = await _cli(target, 'ota rollback');
    } catch (_) {
      // The rollback command reboots the node too; the reply can be lost for
      // the same reason as `ota apply`. The caller verifies that it came back.
      return;
    }
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
