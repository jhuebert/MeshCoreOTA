// Wire probe: arm staging over the CLI, send one raw OP_START, and dump every
// raw RX push the companion reports, so a silent repeater can be told apart
// from a repeater whose replies we simply fail to parse.
//
//   dart run bin/probe.dart --host 192.168.1.165 --password password \
//     --contact XiaoS3 --env Xiao_S3_WIO_repeater_observer \
//     --image /path/to/image.bin
import 'dart:async';
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
  final host = a['host'] ?? '127.0.0.1';
  final port = int.parse(a['port'] ?? '5000');
  final password = a['password'] ?? 'password';
  final env = a['env'] ?? 'Xiao_S3_WIO_repeater_observer';
  final image = File(a['image']!).readAsBytesSync();

  final link = TcpDeviceLink(host: host, port: port);
  await link.connect();
  final client = CompanionClient(link);

  // Dump everything the companion reports as raw RX.
  link.pushes.listen((frame) {
    if (frame.isEmpty) return;
    if (frame[0] != pushCodeLogRxData) {
      print('push 0x${frame[0].toRadixString(16)} (${frame.length} B)');
      return;
    }
    final raw = RawRxFrame.parse(frame);
    if (raw == null) {
      print('raw-rx: unparsable ${_hex(frame)}');
      return;
    }
    final pkt = Packet.readFrom(raw.raw);
    print(
        'raw-rx: ${pkt == null ? 'unparsable' : 'type=0x${pkt.payloadType.toRadixString(16)} '
            'route=${pkt.header & 3} payload=${_hex(pkt.payload)}'}');
  });

  final contacts = await client.listContacts();
  final target = contacts.firstWhere(
      (c) => c.name.toLowerCase().contains((a['contact'] ?? '').toLowerCase()),
      orElse: () => contacts.firstWhere((c) => c.advType == advTypeRepeater));
  print('target: ${target.name}');

  final login = await client.login(target, password);
  print('login: ok=${login.ok} admin=${login.isAdmin}');

  final shaHex = _hex(_sha(image));
  final stage = await client.remoteCli(target,
      'ota stage ${image.length} $shaHex probe-${shaHex.substring(0, 6)}');
  print('stage: $stage');
  final arm = parseStageReply(stage);
  if (arm == null) exit(1);

  // Give the listener a moment, then send exactly one OP_START.
  await Future<void>.delayed(const Duration(seconds: 1));
  final start = buildStart(
    size: image.length,
    sha256: _sha(image),
    targetId: targetIdForEnvironment(env),
    token: arm.token,
  );
  print(
      'sending OP_START ${start.length} B, target=${targetIdForEnvironment(env)} '
      '(0x${targetIdForEnvironment(env).toRadixString(16)})');
  await link.sendRawPacket(PacketBuilder.createRawCustom(start).writeTo());

  await Future<void>.delayed(const Duration(seconds: 6));
  final status = await client.remoteCli(target, 'ota status');
  print('status: $status');
  await link.disconnect();
}
