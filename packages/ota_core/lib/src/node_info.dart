import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'wire.dart';

// --- OP_INFO_REPORT handshake (see examples/simple_repeater/OtaUpdate.h) -----

/// `OP_INFO`: asks the node for its capabilities. Answered in every state —
/// idle, staging, ready, error — so this is the negotiation an app should
/// run before arming anything.
const otaOpInfo = 0x07;

/// `OP_INFO_REPORT` body:
///   wire_version:u8 target:u32le slot:u32le max_literal:u16le
///   features:u32le ver[32] (NUL-padded) sha256[32]
const otaOpInfoReport = 0x08;

/// Frame-format version implemented by the node (currently 1).
const otaWireVersion = 1;

/// `features` bit: the node implements OP_COPY (delta via `OP_COPY`).
const otaFeatDelta = 0x00000001;

/// `features` bit: the node implements apply/rollback (dual app slot).
const otaFeatApply = 0x00000002;

const _infoBodyLen = 79;
const _infoReportLen = 3 + _infoBodyLen + 2;

/// What the node says it is, what it has, and what it can do.
class OtaNodeInfo {
  const OtaNodeInfo({
    required this.wireVersion,
    required this.targetId,
    required this.slotSize,
    required this.maxLiteral,
    required this.features,
    required this.runningVersion,
    required this.runningSha256,
  });

  /// Frame-format version; 1 for the current format.
  final int wireVersion;

  /// The board id the node checks `OP_START` targets against — i.e. the
  /// `targetIdForEnvironment` of the build environment the node runs.
  final int targetId;

  /// Usable bytes of the node's inactive app slot.
  final int slotSize;

  /// Largest payload the node accepts in one `OP_LITERAL`.
  final int maxLiteral;

  /// `otaFeatDelta` | `otaFeatApply`.
  final int features;

  /// The running firmware version string (from `FIRMWARE_VERSION`).
  final String runningVersion;

  /// Full SHA-256 of the running image — the strongest possible delta base
  /// match: a library entry whose image hashes to this exact value *is* the
  /// running image.
  final Uint8List runningSha256;

  bool get supportsDelta => features & otaFeatDelta != 0;
  bool get supportsApply => features & otaFeatApply != 0;
}

/// `OP_INFO` query frame.
Uint8List buildInfo() => buildOp(otaOpInfo);

int _le16(List<int> p, int at) => p[at] | (p[at + 1] << 8);

int _le32(List<int> p, int at) =>
    p[at] | (p[at + 1] << 8) | (p[at + 2] << 16) | (p[at + 3] << 24);

/// Parse an `OP_INFO_REPORT` frame. Returns null for anything else.
///
/// The RESPONSE plaintext arrives zero-padded by the crypto layer, so only
/// the first [_infoReportLen] bytes carry the frame — after it, only zero
/// padding may follow.
OtaNodeInfo? parseInfoReport(List<int> payload) {
  if (payload.length < _infoReportLen) return null;
  final frame = unwrapFrame(payload.sublist(0, _infoReportLen));
  if (frame == null) return null;
  if (frame.length != 3 + _infoBodyLen) return null;
  if (frame[2] != otaOpInfoReport) return null;
  for (var i = _infoReportLen; i < payload.length; i++) {
    if (payload[i] != 0) return null;
  }
  final body = frame.sublist(3);
  final verEnd = body.indexOf(0, 15);
  final end = verEnd < 0 ? 47 : (verEnd > 47 ? 47 : verEnd);
  final runningVersion = String.fromCharCodes(body.sublist(15, end));
  return OtaNodeInfo(
    wireVersion: body[0],
    targetId: _le32(body, 1),
    slotSize: _le32(body, 5),
    maxLiteral: _le16(body, 9),
    features: _le32(body, 11),
    runningVersion: runningVersion,
    runningSha256: Uint8List.fromList(body.sublist(47, 79)),
  );
}

/// Ask the node for its capabilities. Resolves to null when the node does not
/// answer (e.g. firmware older than the handshake) or sends a malformed
/// report. Never throws on the happy path of an old node; errors from the
/// link itself propagate.
Future<OtaNodeInfo?> queryNodeInfo(
  RadioLink link,
  Contact contact, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final done = Completer<OtaNodeInfo?>();
  int? askTag;
  late StreamSubscription<Uint8List> sub;
  sub = link.pushes.listen((frame) {
    if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return;
    final report = binaryResponseReport(frame,
        contactPubKey: contact.publicKey, askTag: askTag);
    if (report == null) return;
    if (done.isCompleted) return;
    done.complete(parseInfoReport(report));
  });
  try {
    final info = buildInfo();
    final sent = await link
        .sendBinaryRequest(contact, [reqTypeOta, info.length, ...info]);
    askTag = sent.tag;
    return await done.future.timeout(timeout, onTimeout: () => null);
  } finally {
    await sub.cancel();
  }
}
