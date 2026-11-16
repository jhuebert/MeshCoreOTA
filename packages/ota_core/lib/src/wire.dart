import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// --- wire format (frozen in M0; mirrors examples/simple_repeater/OtaUpdate.h) ---

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
/// `CMD_SEND_RAW_PACKET` + priority + the packet itself must fit in this.
///
/// The Xiao 1.18 firmware silently drops a longer command — the radio stays
/// alive but nothing is transmitted — so an oversized op is not an error the
/// caller can see, it is a stalled transfer.
const otaStockCompanionFrameLimit = 176;

/// Data bytes one OP_LITERAL may carry when the packet goes through a stock
/// companion: the frame limit less the command, priority, packet header, path
/// length byte, [pathBytes] of route, and the op's own 9 bytes
/// (magic 2 + op 1 + seq 2 + length 2 + CRC 2).
///
/// Clamped to the pure on-air maximum [otaLiteralChunk]; a route long enough to
/// leave no room still yields 1 byte so the transfer fails loudly rather than
/// producing an unsendable frame.
int otaLiteralChunkForCompanion({
  required int pathBytes,
  int frameLimit = otaStockCompanionFrameLimit,
}) {
  final available = frameLimit -
      2 /* command + priority */ -
      1 /* header */ -
      1 /* path_len */ -
      pathBytes -
      (otaFrameOverhead + 2);
  if (available < 1) return 1;
  return available < otaLiteralChunk ? available : otaLiteralChunk;
}

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

/// `OP_ASK body: ret_path_len:u8 [ret_path]` — carries the return itinerary
/// for the OP_REPORT being requested. [retPathLen] is encoded like a packet's
/// path_len byte; empty (0) means zero hop and [retPath] must be empty.
Uint8List buildAsk({required int retPathLen, List<int> retPath = const []}) {
  return buildOp(otaOpAsk, body: [retPathLen, ...retPath]);
}

/// The repeater's answer to an ask.
class OtaReport {
  const OtaReport(this.nextExpected);

  /// Next op seq the node expects (START = 0, then 1, 2, ...).
  final int nextExpected;
}

/// Parse an `OP_REPORT` frame. Returns null for anything else.
OtaReport? parseReport(Uint8List payload) {
  final frame = unwrapFrame(payload);
  if (frame == null) return null;
  if (frame.length != 3 + 2) return null;
  if (frame[2] != otaOpReport) return null;
  return OtaReport(frame[3] | (frame[4] << 8));
}

/// `targetIdForEnvironment` for a build environment: `sha256(pio_env)[0..3]`
/// little endian as a 32-bit int. The release asset names carry the same
/// env id; a node rejects OP_STARTs whose target does not match its own.
int targetIdForEnvironment(String pioEnv) {
  final digest = sha256.convert(pioEnv.codeUnits).bytes;
  return digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24);
}
