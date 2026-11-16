// Minimal op-path probe: arm, START, send ONE op, ask, and dump every RX push.
// Isolates "ops never land" from "asks/reports never work" from "pacing drops".
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _sha(List<int> d) => Uint8List.fromList(sha256.convert(d).bytes);

Future<void> main(List<String> argv) async {
  final a = <String, String>{};
  for (var i = 0; i < argv.length - 1; i++) {
    if (argv[i].startsWith('--')) a[argv[i].substring(2)] = argv[++i];
  }
  final env = a['env'] ?? 'Xiao_S3_WIO_repeater_observer';
  final image = File(a['image']!).readAsBytesSync();
  final ops = a['ops'] ?? 'copy';

  final link =
      TcpDeviceLink(host: a['host']!, port: int.parse(a['port'] ?? '5000'));
  await link.connect();
  final client = CompanionClient(link);

  link.pushes.listen((frame) {
    if (frame.isEmpty) return;
    if (frame[0] == pushCodeBinaryResponse) {
      print('  RX push: BINARY_RESPONSE ${_hex(frame)}');
      return;
    }
    if (frame[0] != pushCodeLogRxData) return;
    final raw = RawRxFrame.parse(frame);
    final pkt = raw == null ? null : Packet.readFrom(raw.raw);
    if (pkt == null) return;
    print('  RX: type=0x${pkt.payloadType.toRadixString(16)} '
        'route=${pkt.header & 3} len=${pkt.payload.length} '
        'payload=${_hex(pkt.payload)}');
  });

  final contacts = await client.listContacts();
  final target = contacts.firstWhere((c) => c.advType == advTypeRepeater);
  await client.login(target, a['password'] ?? 'password');

  final shaHex = _hex(_sha(image));
  final stage = await client.remoteCli(target,
      'ota stage ${image.length} $shaHex probe2-${shaHex.substring(0, 6)}');
  final arm = parseStageReply(stage);
  print('stage: $stage');
  if (arm == null) exit(1);

  final start = buildStart(
    size: image.length,
    sha256: _sha(image),
    targetId: targetIdForEnvironment(env),
    token: arm.token,
  );
  await link.sendBinaryRequest(target, [reqTypeOta, start.length, ...start]);
  print('sent OP_START');
  await Future<void>.delayed(const Duration(seconds: 2));

  final frames = wireOpsFor(
    computeDelta(Uint8List(0), Uint8List.sublistView(image, 0, 4096)).ops,
    literalChunk: otaLiteralChunkForBinaryReq(),
  ).frames;
  final first = frames.first;
  print(
      'first op: ${first.length} B payload, op=0x${first[2].toRadixString(16)}');
  await link.sendBinaryRequest(target, [reqTypeOta, first.length, ...first]);
  print('sent op seq=${first[3] | (first[4] << 8)}');
  await Future<void>.delayed(const Duration(seconds: 2));

  final ask = buildAsk();
  final sent =
      await link.sendBinaryRequest(target, [reqTypeOta, ask.length, ...ask]);
  print('sent OP_ASK (tag=${sent.tag})');
  await Future<void>.delayed(const Duration(seconds: 4));

  print('status: ${await client.remoteCli(target, 'ota status')}');
  if (ops == 'ask-only') {
    print('(ask-only mode)');
  }
  await link.disconnect();
}
