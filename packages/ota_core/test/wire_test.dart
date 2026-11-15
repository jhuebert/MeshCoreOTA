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
      expect(bd.getUint32(40, Endian.little), 0x12345678);
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

    test('buildAsk carries the return itinerary', () {
      final ask = buildAsk(retPathLen: 0x42, retPath: const [0xAA, 0xBB, 0xCC]);
      final unwrapped = unwrapFrame(ask)!;
      expect(unwrapped[2], otaOpAsk);
      expect(unwrapped[3], 0x42);
      expect(unwrapped.sublist(4), [0xAA, 0xBB, 0xCC]);
      final zeroHop = buildAsk(retPathLen: 0);
      expect(unwrapFrame(zeroHop)!.sublist(3), [0x00]);
    });

    test('parseReport reads next_expected', () {
      // 'O' 'T' 0x06 next_lo next_hi crc16
      final report =
          Uint8List.fromList(appendCrc16(const [0x4F, 0x54, 0x06, 0x34, 0x12]));
      expect(parseReport(report)!.nextExpected, 0x1234);
      expect(parseReport(buildEnd(seq: 1)), isNull);
      expect(parseReport(Uint8List.fromList([0x4F, 0x54, 0x06, 0x00])), isNull);
    });

    test('targetIdForEnvironment matches the frozen rule', () {
      // sha256(pio_env)[0..3] little endian; verified independently with
      // Python hashlib (see wire.dart).
      expect(targetIdForEnvironment('Xiao_S3_WIO_repeater'),
          2669264081); // 0x9f19bcd1
      expect(targetIdForEnvironment('RAK_4631_repeater'), 81007613);
      expect(targetIdForEnvironment('PicoW_repeater'), 1413693056);
    });
  });
}
