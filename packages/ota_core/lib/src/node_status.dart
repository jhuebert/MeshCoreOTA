import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'node_info.dart';
import 'wire.dart';

// --- OP_STATUS / OP_PING: the forward-compatible diagnostics API ------------
// Mirrors examples/simple_repeater/OtaUpdate.h. OP_INFO_REPORT stays frozen;
// everything added after this firmware ships lives in OP_STATUS_REPORT, whose
// trailing TLV block is the growth point. Both reports share the identity
// block in node_info.dart, so there is one decoder for the common fields.

const otaOpStatus = 0x10;
const otaOpStatusReport = 0x11;
const otaOpPing = 0x12;
const otaOpPingReport = 0x13;

/// Session state as reported by the node (same order as its State enum).
const otaStateIdle = 0;
const otaStateStaging = 1;
const otaStateReady = 2;
const otaStateError = 3;
const otaStateUnsupported = 4;

const _statusSessionOff = infoBodyLen;
const _statusStateOff = _statusSessionOff + 4;
const _statusErrorOff = _statusStateOff + 1;
const _statusSizeOff = _statusErrorOff + 1;
const _statusWrittenOff = _statusSizeOff + 4;
const _statusExpectOff = _statusWrittenOff + 4;
const _statusCodecsOff = _statusExpectOff + 2;
const _statusExtLenOff = _statusCodecsOff + 1;
const _statusBodyFixed = _statusExtLenOff + 2;

/// Fixed report length (the TLV block is empty in this firmware).
const otaStatusReportLen = 3 + _statusBodyFixed + 2;
const otaPingMax = 16;

/// One reserved extension. `[tag][len][value...]`; unknown tags are ignored.
class OtaExtension {
  const OtaExtension(this.tag, this.value);

  final int tag;
  final List<int> value;
}

/// The node's live session, capability set and progress in one structured
/// report. Not written to flash and available in every state.
class OtaNodeStatus {
  const OtaNodeStatus({
    required this.wireVersion,
    required this.targetId,
    required this.slotSize,
    required this.maxLiteral,
    required this.features,
    required this.runningVersion,
    required this.runningSha256,
    required this.sessionId,
    required this.state,
    required this.error,
    required this.imageSize,
    required this.written,
    required this.nextExpected,
    required this.codecs,
    required this.extensions,
  });

  final int wireVersion;
  final int targetId;
  final int slotSize;
  final int maxLiteral;
  final int features;
  final String runningVersion;
  final Uint8List runningSha256;

  /// Non-zero while an update is armed; changes on every new arm and clears on
  /// abort. A phone restart keeps it, a repeater restart loses it.
  final int sessionId;
  final int state;
  final int error;
  final int imageSize;
  final int written;
  final int nextExpected;

  /// Bitmask of decompressors, e.g. [otaCodecDeflate].
  final int codecs;

  /// Reserved forward-compatibility block; empty in this firmware.
  final List<OtaExtension> extensions;

  bool supports(int bit) => features & bit != 0;
  bool supportsCodec(int bit) => codecs & bit != 0;
  bool get isIdle => state == otaStateIdle;
  bool get isStaging => state == otaStateStaging;
  bool get isReady => state == otaStateReady;
  bool get isError => state == otaStateError;
}

int _le16(List<int> p, int at) => p[at] | (p[at + 1] << 8);
int _le32(List<int> p, int at) =>
    p[at] | (p[at + 1] << 8) | (p[at + 2] << 16) | (p[at + 3] << 24);

/// Find a framed report of the expected op in a possibly zero-padded payload.
/// Scanning longest-first keeps a report whose CRC happens to be 0x0000 from
/// being mistaken for a shorter one in the crypto layer's padding.
Uint8List? _framedReport(List<int> payload, int op) {
  for (var len = payload.length; len >= 5; len--) {
    final frame = unwrapFrame(payload.sublist(0, len));
    if (frame == null || frame[2] != op) continue;
    if (payload.skip(len).any((byte) => byte != 0)) continue;
    return frame;
  }
  return null;
}

Uint8List buildStatusQuery() => buildOp(otaOpStatus);

/// Decode an OP_STATUS_REPORT. Returns null for any other or malformed frame.
OtaNodeStatus? parseStatusReport(List<int> payload) {
  final frame = _framedReport(payload, otaOpStatusReport);
  if (frame == null || frame.length < 3 + _statusBodyFixed) return null;
  final body = frame.sublist(3);
  final extLen = _le16(body, _statusExtLenOff);
  if (body.length != _statusBodyFixed + extLen) return null;

  final verEnd = body.indexOf(0, infoVersionOff);
  final end =
      verEnd < 0 ? infoShaOff : (verEnd > infoShaOff ? infoShaOff : verEnd);
  final extensions = <OtaExtension>[];
  var at = _statusBodyFixed;
  final extEnd = _statusBodyFixed + extLen;
  while (at < extEnd) {
    if (at + 2 > extEnd) return null;
    final len = body[at + 1];
    if (at + 2 + len > extEnd) return null;
    extensions.add(OtaExtension(
        body[at], Uint8List.fromList(body.sublist(at + 2, at + 2 + len))));
    at += 2 + len;
  }

  return OtaNodeStatus(
    wireVersion: body[infoWireVerOff],
    targetId: _le32(body, infoTargetOff),
    slotSize: _le32(body, infoSlotOff),
    maxLiteral: _le16(body, infoMaxLiteralOff),
    features: _le32(body, infoFeaturesOff),
    runningVersion: String.fromCharCodes(body.sublist(infoVersionOff, end)),
    runningSha256: Uint8List.fromList(body.sublist(infoShaOff, infoBodyLen)),
    sessionId: _le32(body, _statusSessionOff),
    state: body[_statusStateOff],
    error: body[_statusErrorOff],
    imageSize: _le32(body, _statusSizeOff),
    written: _le32(body, _statusWrittenOff),
    nextExpected: _le16(body, _statusExpectOff),
    codecs: body[_statusCodecsOff],
    extensions: extensions,
  );
}

/// A tagged echo of 1..[otaPingMax] bytes; answered in every state, read-only.
Uint8List buildPing(Uint8List payload) {
  assert(payload.isNotEmpty && payload.length <= otaPingMax);
  return buildOp(otaOpPing, body: payload);
}

Uint8List? parsePingReport(List<int> payload) {
  final frame = _framedReport(payload, otaOpPingReport);
  if (frame == null || frame.length < 5) return null;
  return Uint8List.fromList(frame.sublist(3));
}

/// One shared request/response pump for both new report types.
Future<T?> _queryOtaReport<T>(
  RadioLink link,
  Contact contact,
  Uint8List Function() build,
  T? Function(List<int>) parse,
  int exactLength,
  Duration timeout,
) async {
  final done = Completer<T?>();
  int? askTag;
  late StreamSubscription<Uint8List> sub;
  sub = link.pushes.listen((frame) {
    if (frame.isEmpty || frame[0] != pushCodeBinaryResponse) return;
    final report = binaryResponseReport(frame,
        contactPubKey: contact.publicKey,
        askTag: askTag,
        exactLength: exactLength);
    if (report == null || done.isCompleted) return;
    done.complete(parse(report));
  });
  try {
    final op = build();
    final sent =
        await link.sendBinaryRequest(contact, [reqTypeOta, op.length, ...op]);
    askTag = sent.tag;
    return await done.future.timeout(timeout, onTimeout: () => null);
  } finally {
    await sub.cancel();
  }
}

Future<OtaNodeStatus?> queryNodeStatus(
  RadioLink link,
  Contact contact, {
  Duration timeout = const Duration(seconds: 3),
}) =>
    _queryOtaReport(link, contact, buildStatusQuery, parseStatusReport,
        otaStatusReportLen, timeout);

/// Measure the live REQ/RESPONSE path. Returns the echoed bytes, or null on
/// timeout. Defaults to a small fixed payload so callers need no setup.
Future<Uint8List?> pingNode(
  RadioLink link,
  Contact contact, {
  Uint8List? payload,
  Duration timeout = const Duration(seconds: 3),
}) {
  final echo = payload ?? Uint8List.fromList(const [1, 2, 3, 4]);
  return _queryOtaReport(link, contact, () => buildPing(echo), parsePingReport,
      3 + echo.length + 2, timeout);
}
