import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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

List<int> _le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

Uint8List _padded(List<int> bytes) => Uint8List.fromList(
    [...bytes, ...List<int>.filled((16 - bytes.length % 16) % 16, 0)]);

Uint8List _push(int tag, Uint8List payload) => Uint8List.fromList([
      pushCodeBinaryResponse,
      0,
      ..._le32(tag),
      ..._padded(payload),
    ]);

Uint8List _pushPrefixed(int tag, Uint8List payload) => Uint8List.fromList([
      pushCodeBinaryResponse,
      0,
      ...testContact.publicKey.sublist(0, 6),
      ..._le32(tag),
      ..._padded(payload),
    ]);

Uint8List _metaReport(int size, List<ImageSegment> segs, Uint8List hash) {
  final body = <int>[..._le32(size), 0, segs.length];
  for (final s in segs) {
    body.addAll(_le32(s.offset));
    body.addAll(_le32(s.length));
  }
  body.addAll(List<int>.filled(blockHashMaxSegments * 8 - segs.length * 8, 0));
  body.addAll(hash);
  return buildOp(otaOpBlockHashReport, body: body);
}

Uint8List _rangeReport(List<BlockHashRange> ranges, Uint8List running,
    {int Function(int i)? statusFor, int op = otaOpBlockHashReport}) {
  final body = <int>[..._le32(running.length), ranges.length];
  for (var i = 0; i < ranges.length; i++) {
    final r = ranges[i];
    final status = statusFor?.call(i) ?? 0;
    body.addAll(_le32(r.offset));
    body.add(status);
    if (status == 0) {
      final end = r.length == 0 ? running.length : r.offset + r.length;
      body.addAll(sha256.convert(running.sublist(r.offset, end)).bytes);
    } else {
      body.addAll(List<int>.filled(blockHashLength, 0));
    }
  }
  return buildOp(op, body: body);
}

void main() {
  test('query frame is compact and batches four ranges', () {
    final query = buildBlockHashQuery(const [
      BlockHashRange(0, 1024),
      BlockHashRange(1024, 1024),
      BlockHashRange(2048, 1024),
      BlockHashRange(3072, 1024),
    ]);
    expect(query[2], otaOpBlockHash);
    expect(query.length, 3 + 1 + 4 * 8 + 2);
    expect(unwrapFrame(query), isNotNull);
    // REQ datagram must fit both the on-air payload and the companion command.
    expect(2 + 1 + 1 + query.length, lessThanOrEqualTo(176));
  });

  test('metadata report parses size, segments and whole hash', () {
    final hash = Uint8List.fromList(List<int>.generate(32, (i) => i + 3));
    final report = _metaReport(4096, const [ImageSegment(32, 400)], hash);
    expect(report.length, 3 + 4 + 1 + 1 + blockHashMaxSegments * 8 + 32 + 2);
    final parsed = parseBlockHashReport([...report, 0, 0, 0])!;
    expect(parsed.runningSize, 4096);
    expect(parsed.metadata!.size, 4096);
    expect(parsed.metadata!.segments.length, 1);
    expect(parsed.metadata!.segments.single.offset, 32);
    expect(parsed.metadata!.segments.single.length, 400);
    expect(parsed.metadata!.sha256, hash);
  });

  test('range report parses four hashes and their statuses', () {
    final running =
        Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xFF));
    const ranges = [
      BlockHashRange(0, 512),
      BlockHashRange(512, 512),
      BlockHashRange(0, 0),
      BlockHashRange(4096, 512),
    ];
    final report =
        _rangeReport(ranges, running, statusFor: (i) => i == 3 ? 1 : 0);
    final parsed = parseBlockHashReport(report)!;
    expect(parsed.results.length, 4);
    expect(parsed.results.take(3).map((r) => r.ok), everyElement(isTrue));
    expect(parsed.results.last.status, BlockHashStatus.outOfBounds);
    expect(
      parsed.results.first.sha256,
      sha256.convert(running.sublist(0, 512)).bytes,
    );
  });

  test('batched find query and report round-trip', () {
    final query = buildBlockFindQuery(
      length: 256,
      start: 0,
      end: 8192,
      fingerprints: const [0x11, 0x22, 0x33],
    );
    expect(query[2], otaOpBlockFind);
    expect(query.length, 3 + 13 + 3 * 8 + 2);
    expect(unwrapFrame(query), isNotNull);

    final report = buildOp(otaOpBlockFindReport, body: const [
      3, // three fingerprints
      0, // no hits
      2, 32, 0, 0, 0, 64, 0, 0, 0, // two offsets for the second
      1, 128, 0, 0, 0, // one for the third
    ]);
    final parsed = parseBlockFindReport(report)!;
    expect(parsed.length, 3);
    expect(parsed[0], isEmpty);
    expect(parsed[1], [32, 64]);
    expect(parsed[2], [128]);
    expect(parseBlockFindReport([...report, 0, 0]), isNotNull);
  });

  test('parse rejects garbage and wrong op', () {
    expect(parseBlockHashReport(const [0x4F, 0x54]), isNull);
    expect(parseBlockHashReport(buildOp(otaOpEnd, seq: 1)), isNull);
    final bad = Uint8List.fromList(_metaReport(1, const [], Uint8List(32)));
    bad[10] ^= 0x40;
    expect(parseBlockHashReport(bad), isNull);
  });

  test('client reads metadata and batched ranges through the binary path',
      () async {
    final running =
        Uint8List.fromList(List<int>.generate(4096, (i) => i & 0xFF));
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      final frame = Uint8List.fromList(reqData.sublist(2));
      final count = frame[3];
      final ranges = <BlockHashRange>[];
      for (var i = 0; i < count; i++) {
        final at = 4 + i * 8;
        ranges.add(BlockHashRange(
          frame[at] |
              (frame[at + 1] << 8) |
              (frame[at + 2] << 16) |
              (frame[at + 3] << 24),
          frame[at + 4] |
              (frame[at + 5] << 8) |
              (frame[at + 6] << 16) |
              (frame[at + 7] << 24),
        ));
      }
      final reply = count == 0
          ? _metaReport(running.length, const [ImageSegment(32, 400)],
              Uint8List.fromList(sha256.convert(running).bytes))
          : _rangeReport(ranges, running);
      link.simulatePush(_push(tag, reply));
    };

    final client = BlockHashClient(
        link: link, contact: testContact, timeout: const Duration(seconds: 1));
    final info = await client.metadata();
    expect(info.size, running.length);
    expect(info.segments.single.offset, 32);
    final ranges = List<BlockHashRange>.generate(
        4, (i) => BlockHashRange(i * 512, 512),
        growable: false);
    final results = await client.query(ranges);
    expect(results.results.length, 4);
    expect(results.results.first.sha256,
        sha256.convert(running.sublist(0, 512)).bytes);
    await client.close();
  });

  test('client accepts the pubkey-prefix push layout and retries a silent node',
      () async {
    var calls = 0;
    final running = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      calls++;
      if (calls == 1) return; // first query is silently dropped
      link.simulatePush(_pushPrefixed(
          tag, _rangeReport(const [BlockHashRange(0, 16)], running)));
    };
    final client = BlockHashClient(
        link: link,
        contact: testContact,
        timeout: const Duration(milliseconds: 150),
        retries: 2);
    final results = await client.query(const [BlockHashRange(0, 16)]);
    expect(calls, 2);
    expect(results.results.single.ok, isTrue);
    await client.close();
  });

  test('staged hash query uses its own op but the same compact body', () {
    final running = buildStagedHashQuery(const [BlockHashRange(0, 1024)]);
    final staged = buildBlockHashQuery(const [BlockHashRange(0, 1024)]);
    expect(running[2], otaOpStagedHash);
    expect(staged[2], otaOpBlockHash);
    expect(running.sublist(3, running.length - 2),
        staged.sublist(3, staged.length - 2));
    expect(unwrapFrame(running), isNotNull);
  });

  test('staged hash report parses with the shared decoder', () {
    final staged = Uint8List.fromList(List<int>.generate(64, (i) => i + 3));
    final report = _rangeReport(const [BlockHashRange(0, 16)], staged,
        op: otaOpStagedHashReport);
    final parsed = parseStagedHashReport([...report, 0, 0])!;
    expect(parsed.results.single.ok, isTrue);
    expect(parsed.results.single.sha256,
        sha256.convert(staged.sublist(0, 16)).bytes);
    expect(parseBlockHashReport(report), isNull); // wrong op must not parse
  });

  test('staged hash client reads the written prefix', () async {
    final staged = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final link = FakeDeviceLink(snr: 6.0, rssi: -70);
    link.binaryRequestHandler = (contact, reqData, tag) async {
      expect(reqData[0], reqTypeOta);
      final frame = Uint8List.fromList(reqData.sublist(2, 2 + reqData[1]));
      expect(frame[2], otaOpStagedHash);
      link.simulatePush(_push(
          tag,
          _rangeReport(const [BlockHashRange(0, 16)], staged,
              op: otaOpStagedHashReport)));
    };
    final client = BlockHashClient(
        link: link,
        contact: testContact,
        staged: true,
        timeout: const Duration(seconds: 1));
    final report = await client.query(const [BlockHashRange(0, 16)]);
    expect(report.results.single.sha256,
        sha256.convert(staged.sublist(0, 16)).bytes);
    await client.close();
  });
}
