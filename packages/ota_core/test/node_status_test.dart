import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:test/test.dart';

final testContact = Contact(
  publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i + 1)),
  name: 'tower-1',
  advType: advTypeRepeater,
  outPathLen: -1,
);

List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

Uint8List _padded32(List<int> bytes) {
  final out = Uint8List(32);
  out.setRange(0, bytes.length > 32 ? 32 : bytes.length, bytes);
  return out;
}

Uint8List _statusReport({
  int sessionId = 0x12345678,
  int state = otaStateStaging,
  int error = 0,
  int imageSize = 4096,
  int written = 1024,
  int nextExpected = 5,
  int codecs = otaCodecDeflate,
  int features = otaFeatDelta |
      otaFeatApply |
      otaFeatBlockHash |
      otaFeatStagedHash |
      otaFeatStatus |
      otaFeatPing,
  List<OtaExtension> extensions = const [],
}) {
  final ext = <int>[
    for (final e in extensions) ...[e.tag, e.value.length, ...e.value],
  ];
  final body = <int>[
    otaWireVersion,
    ..._le32(0xDEADBEEF),
    ..._le32(0x200000),
    ..._le16(132),
    ..._le32(features),
    ..._padded32('test-fw-1.0.0'.codeUnits),
    ...List<int>.generate(32, (i) => i + 0xA0),
    ..._le32(sessionId),
    state,
    error,
    ..._le32(imageSize),
    ..._le32(written),
    ..._le16(nextExpected),
    codecs,
    ..._le16(ext.length),
    ...ext,
  ];
  return buildOp(otaOpStatusReport, body: body);
}

Uint8List _push(int tag, Uint8List payload) {
  final padded = (payload.length + 15) & ~15;
  return Uint8List.fromList([
    pushCodeBinaryResponse,
    0,
    ..._le32(tag),
    ...payload,
    ...List<int>.filled(padded - payload.length, 0),
  ]);
}

void main() {
  test('status report reads the identity block and the session fields', () {
    final status = parseStatusReport(_statusReport())!;
    expect(status.wireVersion, otaWireVersion);
    expect(status.targetId, 0xDEADBEEF);
    expect(status.slotSize, 0x200000);
    expect(status.maxLiteral, 132);
    expect(status.runningVersion, 'test-fw-1.0.0');
    expect(status.runningSha256, List<int>.generate(32, (i) => i + 0xA0));
    expect(status.sessionId, 0x12345678);
    expect(status.state, otaStateStaging);
    expect(status.isStaging, isTrue);
    expect(status.error, 0);
    expect(status.imageSize, 4096);
    expect(status.written, 1024);
    expect(status.nextExpected, 5);
    expect(status.supportsCodec(otaCodecDeflate), isTrue);
    expect(status.supports(otaFeatStagedHash), isTrue);
    expect(status.supports(otaFeatPing), isTrue);
  });

  test('status report decodes the forward-compatible TLV block', () {
    final status = parseStatusReport(_statusReport(extensions: [
      const OtaExtension(1, [0xAA, 0xBB]),
      const OtaExtension(7, []),
    ]))!;
    expect(status.extensions, hasLength(2));
    expect(status.extensions[0].tag, 1);
    expect(status.extensions[0].value, [0xAA, 0xBB]);
    expect(status.extensions[1].tag, 7);
    expect(status.extensions[1].value, isEmpty);
  });

  test('status report tolerates zero padding but rejects junk and other ops',
      () {
    final report = _statusReport();
    expect(report.length, otaStatusReportLen);
    expect(parseStatusReport([...report, 0, 0, 0])!.sessionId, 0x12345678);
    expect(parseStatusReport([...report, 1]), isNull);
    final corrupt = Uint8List.fromList(report);
    corrupt[20] ^= 0x40;
    expect(parseStatusReport(corrupt), isNull);
    expect(parseStatusReport(buildOp(otaOpEnd, seq: 1)), isNull);
  });

  test('status report rejects a truncated TLV', () {
    final body = <int>[
      ..._statusReport().sublist(3, 3 + 98),
      ..._le16(3),
      1,
      4,
      0xAA,
    ];
    expect(parseStatusReport(buildOp(otaOpStatusReport, body: body)), isNull);
  });

  test('queryNodeStatus round-trips through the binary-request path', () async {
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      final query = buildStatusQuery();
      expect(reqData, [reqTypeOta, query.length, ...query]);
      link.simulatePush(_push(tag, _statusReport()));
    };
    final status = await queryNodeStatus(link, testContact,
        timeout: const Duration(seconds: 1));
    expect(status, isNotNull);
    expect(status!.sessionId, 0x12345678);
    expect(status.written, 1024);
  });

  test('ping echoes the payload over the same path', () async {
    final echo = Uint8List.fromList([9, 8, 7, 6]);
    final ping = buildPing(echo);
    expect(ping[2], otaOpPing);
    expect(unwrapFrame(ping), isNotNull);
    expect(parsePingReport(buildOp(otaOpPingReport, body: echo)), echo);
    expect(parsePingReport(buildOp(otaOpEnd, seq: 1)), isNull);

    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      expect(reqData, [reqTypeOta, ping.length, ...ping]);
      link.simulatePush(_push(tag, buildOp(otaOpPingReport, body: echo)));
    };
    expect(
        await pingNode(link, testContact,
            payload: echo, timeout: const Duration(seconds: 1)),
        echo);
  });
}
