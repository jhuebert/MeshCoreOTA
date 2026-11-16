import 'dart:typed_data';

import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

void main() {
  group('crc16CcittFalse', () {
    // Vectors cross-checked against the firmware's crc16_ccitt (Python
    // binascii.crc_hqx with init 0xFFFF is CRC-16/CCITT-FALSE).
    test('matches the reference vectors', () {
      expect(crc16CcittFalse(const []), 0xFFFF);
      expect(crc16CcittFalse(const [0x4F, 0x54, 0x01, 0x00, 0x00]), 0xED67);
      expect(
          crc16CcittFalse(
              const [0x4F, 0x54, 0x03, 0x01, 0x00, 0x05, 0x41, 0x00]),
          0x84C1);
      expect(
        crc16CcittFalse(Uint8List.fromList(List<int>.generate(256, (i) => i))),
        0x3FBD,
      );
    });
  });

  group('frame build/parse round trip', () {
    test('unwrapFrame accepts well-formed frames', () {
      final frame = buildEnd(seq: 7);
      final unwrapped = unwrapFrame(frame);
      expect(unwrapped, isNotNull);
      expect(unwrapped![2], otaOpEnd);
      expect(unwrapped[3], 7);
      expect(unwrapped[4], 0);
    });

    test('unwrapFrame rejects bad magic and bad CRC', () {
      final frame = buildEnd(seq: 1);
      expect(unwrapFrame(Uint8List.fromList([...frame])..[0] = 0x58), isNull);
      expect(
          unwrapFrame(
              Uint8List.fromList([...frame])..[frame.length - 1] ^= 0x55),
          isNull);
      expect(unwrapFrame(Uint8List.fromList([0x4F, 0x54])), isNull);
    });

    test('buildStart emits the frozen 44-byte body', () {
      final sha = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final frame = buildStart(
          size: 1000, sha256: sha, targetId: 0xDEADBEEF, token: 0x12345678);
      final body = frame.sublist(5, frame.length - 2);
      expect(body.length, 44);
      final bd = ByteData.sublistView(body);
      expect(bd.getUint32(0, Endian.little), 1000);
      expect(body.sublist(4, 36), sha);
      expect(bd.getUint32(36, Endian.little), 0xDEADBEEF);
      // The token is four opaque bytes printed in memory order; writing the
      // parsed value big-endian keeps those bytes in the printed order.
      expect(bd.getUint32(40, Endian.big), 0x12345678);
    });

    test('buildCopy/buildLiteralChunk round trip via the node-side seq rules',
        () {
      final copy = buildCopy(seq: 3, baseOffset: 0x01020304, length: 0x0203);
      final literal =
          buildLiteralChunk(seq: 4, data: Uint8List.fromList([9, 8, 7]));
      expect(copy[2], otaOpCopy);
      expect(copy[3] | (copy[4] << 8), 3);
      final copyBody = ByteData.sublistView(copy.sublist(5, copy.length - 2));
      expect(copyBody.getUint32(0, Endian.little), 0x01020304);
      expect(copyBody.getUint16(4, Endian.little), 0x0203);
      expect(literal[2], otaOpLiteral);
      expect(literal[5] | (literal[6] << 8), 3);
      expect(literal.sublist(7, literal.length - 2), [9, 8, 7]);
    });

    test('buildAsk carries no body', () {
      // v2: the OP_REPORT comes back through the stock REQ reply routing.
      final ask = buildAsk();
      final unwrapped = unwrapFrame(ask)!;
      expect(unwrapped.length, 3 + 0);
      expect(unwrapped[2], otaOpAsk);
    });

    test('parseReport reads next_expected', () {
      // 'O' 'T' 0x06 next_lo next_hi crc16
      final report =
          Uint8List.fromList(appendCrc16(const [0x4F, 0x54, 0x06, 0x34, 0x12]));
      expect(parseReport(report)!.nextExpected, 0x1234);
      expect(parseReport(buildEnd(seq: 1)), isNull);
      expect(parseReport(Uint8List.fromList([0x4F, 0x54, 0x06, 0x00])), isNull);
    });

    test('parseReport tolerates the crypto layer zero padding', () {
      // The RESPONSE plaintext is padded to a 16-byte block; only zeros may
      // follow the 7-byte frame.
      final report =
          Uint8List.fromList(appendCrc16(const [0x4F, 0x54, 0x06, 0x34, 0x12]));
      expect(parseReport([...report, 0, 0, 0, 0, 0, 0, 0, 0])!.nextExpected,
          0x1234);
      expect(parseReport([...report, 0x01]), isNull);
    });

    test('parseBinaryResponse accepts both companion record layouts', () {
      final report = appendCrc16(const [0x4F, 0x54, 0x06, 0x34, 0x12]);
      final pubkey6 = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
      const tag = 0x12345678;
      // Older companion: [8C][00][tag(4)][report]
      final layoutA = Uint8List.fromList([
        0x8C,
        0x00,
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...report,
      ]);
      // Current companion: [8C][00][pubkey6][tag(4)][report]
      final layoutB = Uint8List.fromList([
        0x8C,
        0x00,
        ...pubkey6,
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...report,
      ]);
      final contact =
          Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 1, 2]);
      expect(
          parseBinaryResponse(layoutA, contactPubKey: contact, askTag: tag)
              ?.nextExpected,
          0x1234);
      expect(
          parseBinaryResponse(layoutB, contactPubKey: contact, askTag: tag)
              ?.nextExpected,
          0x1234);
      // A different tag is refused.
      expect(
          parseBinaryResponse(layoutA, contactPubKey: contact, askTag: tag + 1),
          isNull);
      // pubkey layout with a mismatched sender prefix is refused.
      final wrongSender = Uint8List.fromList([
        0x8C,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        tag & 0xFF,
        (tag >> 8) & 0xFF,
        (tag >> 16) & 0xFF,
        (tag >> 24) & 0xFF,
        ...report,
      ]);
      expect(
          parseBinaryResponse(wrongSender, contactPubKey: contact, askTag: tag),
          isNull);
    });

    test('targetIdForEnvironment matches the frozen rule', () {
      // sha256(pio_env)[0..3] little endian; verified independently with
      // Python hashlib (see wire.dart).
      expect(targetIdForEnvironment('Xiao_S3_WIO_repeater'),
          2669264081); // 0x9f19bcd1
      expect(targetIdForEnvironment('RAK_4631_repeater'), 81007613);
      expect(targetIdForEnvironment('PicoW_repeater'), 1413693056);
    });

    test('literal chunks fit a stock companion frame', () {
      // 176 - 1 (cmd) - 32 (pubkey) - 1 (REQ_TYPE_OTA) - 1 (frame length)
      //      - 7 (frame overhead) - 2 (literal length) = 132.
      expect(otaLiteralChunkForBinaryReq(), 132);
      // Never more than the pure on-air maximum.
      expect(otaLiteralChunkForBinaryReq(), lessThanOrEqualTo(otaLiteralChunk));
      // A transport too small for the op envelope clamps to 1 rather than
      // going negative.
      expect(otaLiteralChunkForBinaryReq(frameLimit: 40), 1);
    });
  });
}
