import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// --- wire format (mirrors examples/simple_repeater/OtaUpdate.h) ------------
// v2: the op stream rides inside REQ/RESPONSE datagrams. The app ships each
// op as a CMD_SEND_BINARY_REQ (`[pub_key][REQ_TYPE_OTA][frame_len][op frame]`)
// to the companion, which encrypts it as an ordinary REQ datagram to the
// node; the plaintext is padded by the crypto layer to a 16-byte block, so
// the length byte is what the node uses to slice the frame back out. The
// node answers an OP_ASK with an OP_REPORT inside the RESPONSE, which the
// companion surfaces as PUSH_CODE_BINARY_RESPONSE. Intermediate nodes only
// ever forward ordinary request/response traffic.

const otaMagic0 = 0x4F; // 'O'
const otaMagic1 = 0x54; // 'T'

const otaOpNop = 0x00;
const otaOpStart = 0x01;
const otaOpCopy = 0x02;
const otaOpLiteral = 0x03;
const otaOpEnd = 0x04;
const otaOpAsk = 0x05;
const otaOpReport = 0x06;

/// `magic(2) + op(1) + seq(2) + body + crc16(2)` for op packets; ASK/REPORT/
/// NOP carry no seq, hence the minimum payload the node accepts.
const otaFrameOverhead = 2 + 1 + 2 + 2;

/// Maximum on-air payload (`MAX_PACKET_PAYLOAD` in the firmware).
const otaMaxPayload = 184;

/// LITERAL data bytes that fit one op packet.
const otaLiteralChunk = otaMaxPayload - otaFrameOverhead - 2;

/// The stock companion's transport frame limit (`MAX_FRAME_SIZE` in the
/// firmware's BaseSerialInterface.h), measured after the 3-byte serial header:
/// the command plus its arguments must fit in this.
///
/// The Xiao 1.18 firmware silently drops a longer command — the radio stays
/// alive but nothing is transmitted — so an oversized op is not an error the
/// caller can see, it is a stalled transfer.
const otaStockCompanionFrameLimit = 176;

/// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
/// Bitwise — identical to the firmware's `crc16_ccitt`.
int crc16CcittFalse(Iterable<int> data) {
  int crc = 0xFFFF;
  for (final byte in data) {
    crc ^= (byte & 0xFF) << 8;
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) != 0
          ? ((crc << 1) ^ 0x1021) & 0xFFFF
          : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// Data bytes one OP_LITERAL may carry when the op rides inside a
/// `CMD_SEND_BINARY_REQ` datagram
/// (`[cmd(1)][pub_key(32)][req_data…]` ≤ [frameLimit]).
///
/// `req_data` is `REQ_TYPE_OTA(1) | frame_len(1) | OTA frame`; the OTA frame
/// overhead is 7 and the literal carries a 2-byte length. Everything inside
/// the frame limit travels over the app↔companion hop only; the datagram the
/// companion puts on air is a standard REQ.
int otaLiteralChunkForBinaryReq(
    {int frameLimit = otaStockCompanionFrameLimit}) {
  final chunk = frameLimit -
      1 - // cmd
      32 - // contact pubkey
      1 - // REQ_TYPE_OTA
      1 - // frame length byte
      otaFrameOverhead - // magic + op + seq + crc
      2; // literal length prefix
  if (chunk < 1) return 1;
  return chunk < otaLiteralChunk ? chunk : otaLiteralChunk;
}

/// Append the wire CRC-16 (little endian) to [payload].
Uint8List appendCrc16(List<int> payload) {
  final crc = crc16CcittFalse(payload);
  return Uint8List.fromList([...payload, crc & 0xFF, (crc >> 8) & 0xFF]);
}

/// Verify a frame's magic and CRC. Returns the frame with the CRC stripped,
/// or null when malformed.
Uint8List? unwrapFrame(List<int> payload) {
  if (payload.length < 5) return null;
  if (payload[0] != otaMagic0 || payload[1] != otaMagic1) return null;
  final n = payload.length;
  final stored = payload[n - 2] | (payload[n - 1] << 8);
  if (crc16CcittFalse(payload.sublist(0, n - 2)) != stored) return null;
  return Uint8List.fromList(payload.sublist(0, n - 2));
}

Uint8List buildOp(int op, {int? seq, List<int> body = const []}) {
  final frame = <int>[otaMagic0, otaMagic1, op];
  if (seq != null) {
    frame.add(seq & 0xFF);
    frame.add((seq >> 8) & 0xFF);
  }
  frame.addAll(body);
  return appendCrc16(frame);
}

/// `OP_START body: size:u32 sha256[32] target:u32 token:u32` (44 bytes).
///
/// The token is four opaque bytes, not a number: the firmware prints them in
/// memory order (`token=%02x%02x%02x%02x` over `token[0..3]`) and compares
/// them with `memcmp`. Writing the parsed integer little-endian would send the
/// bytes reversed and the node would refuse the arm (err=7). Kept as an int
/// for the CLI surface; written big-endian so the four bytes go out exactly as
/// printed.
Uint8List buildStart({
  required int size,
  required List<int> sha256,
  required int targetId,
  required int token,
}) {
  assert(sha256.length == 32);
  final body = Uint8List(44);
  final bd = ByteData.sublistView(body);
  bd.setUint32(0, size, Endian.little);
  body.setRange(4, 36, sha256);
  bd.setUint32(36, targetId, Endian.little);
  bd.setUint32(40, token, Endian.big);
  return buildOp(otaOpStart, seq: 0, body: body);
}

/// `OP_COPY body: base_off:u32 len:u16` (6 bytes).
Uint8List buildCopy(
    {required int seq, required int baseOffset, required int length}) {
  assert(length >= 1 && length <= 0xFFFF);
  final body = Uint8List(6);
  final bd = ByteData.sublistView(body);
  bd.setUint32(0, baseOffset, Endian.little);
  bd.setUint16(4, length, Endian.little);
  return buildOp(otaOpCopy, seq: seq, body: body);
}

/// `OP_LITERAL body: len:u16 data[len]` for one ≤[otaLiteralChunk]-byte chunk.
Uint8List buildLiteralChunk({required int seq, required List<int> data}) {
  assert(data.length <= otaLiteralChunk);
  final body = Uint8List(2 + data.length);
  ByteData.sublistView(body).setUint16(0, data.length, Endian.little);
  body.setRange(2, body.length, data);
  return buildOp(otaOpLiteral, seq: seq, body: body);
}

/// `OP_END`: no body.
Uint8List buildEnd({required int seq}) => buildOp(otaOpEnd, seq: seq);

/// `OP_ASK`: no body. The OP_REPORT comes back through the stock REQ reply
/// routing (the target's stored out_path for the sender, or a flood when none
/// is known), exactly like a status response — there is no return itinerary
/// to carry.
Uint8List buildAsk() => buildOp(otaOpAsk);

/// The repeater's answer to an ask.
class OtaReport {
  const OtaReport(this.nextExpected);

  /// Next op seq the node expects (START = 0, then 1, 2, ...).
  final int nextExpected;
}

/// Parse an `OP_REPORT` frame. Returns null for anything else.
///
/// The RESPONSE plaintext arrives zero-padded by the crypto layer, so only
/// the first 7 bytes carry the frame — after it, only zero padding may
/// follow.
OtaReport? parseReport(List<int> payload) {
  if (payload.length < 7) return null;
  final frame = unwrapFrame(payload.sublist(0, 7));
  if (frame == null) return null;
  if (frame.length != 3 + 2) return null;
  if (frame[2] != otaOpReport) return null;
  for (var i = 7; i < payload.length; i++) {
    if (payload[i] != 0) return null;
  }
  return OtaReport(frame[3] | (frame[4] << 8));
}

/// `PUSH_CODE_BINARY_RESPONSE` (0x8C), emitted by the companion when the
/// target of our `CMD_SEND_BINARY_REQ` answers with a RESPONSE.
///
/// Two record layouts circulate in the field, and this parser accepts both:
///
///   `[8C][00][tag(4)][payload…]`                      older companions
///   `[8C][00][pubkey_prefix(6)][tag(4)][payload…]`    current companions
///
/// The pubkey prefix (when present) is the responder's truncated identity —
/// checked against [contactPubKey]. The tag is checked against [askTag] when
/// known (the ask is always the newest in-flight request, so a well-formed
/// report for this contact while an ask is out is the answer either way).
/// Returns the REPORT when the push parses, else null.
OtaReport? parseBinaryResponse(Uint8List frame,
    {required Uint8List contactPubKey, int? askTag}) {
  if (frame.isEmpty || frame[0] != 0x8C) return null;
  // Candidate frame layouts: tag at 2 (no pubkey prefix) or tag at 8.
  for (final tagAt in [2, 8]) {
    if (frame.length < tagAt + 4 + 7) continue;
    if (tagAt == 8) {
      var prefixOk = true;
      for (var i = 0; i < 6; i++) {
        if (frame[2 + i] != contactPubKey[i]) {
          prefixOk = false;
          break;
        }
      }
      if (!prefixOk) continue;
    }
    final tag = frame[tagAt] |
        (frame[tagAt + 1] << 8) |
        (frame[tagAt + 2] << 16) |
        (frame[tagAt + 3] << 24);
    if (askTag != null && tag != askTag) continue;
    final report = parseReport(frame.sublist(tagAt + 4));
    if (report != null) return report;
  }
  return null;
}

/// `targetIdForEnvironment` for a build environment: `sha256(pio_env)[0..3]`
/// little endian as a 32-bit int. The release asset names carry the same
/// env id; a node rejects OP_STARTs whose target does not match its own.
int targetIdForEnvironment(String pioEnv) {
  final digest = sha256.convert(pioEnv.codeUnits).bytes;
  return digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24);
}
