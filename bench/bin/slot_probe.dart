// One-packet OTA slot-size rejection probe. Sends only OP_START; no image data.
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  const host = '192.168.1.165';
  const contactName = 'XiaoS3 Repeater';
  const password = 'password';
  const env = 'Xiao_S3_WIO_repeater_observer';
  const size = 4000000;
  final sha =
      Uint8List(32); // any well-formed digest: slot-size check comes first

  final link = TcpDeviceLink(host: host);
  await link.connect();
  final client = CompanionClient(link);
  final contacts = await client.listContacts();
  final target = contacts.firstWhere((c) => c.name.contains(contactName));
  final login = await client.login(target, password);
  if (!login.ok || !login.isAdmin) throw StateError('admin login failed');

  final reply = await client.remoteCli(
    target,
    'ota stage $size ${_hex(sha)} oversize-probe',
  );
  final arm = parseStageReply(reply);
  stdout.writeln('stage: $reply');
  if (arm == null) throw StateError('arm refused');

  final start = buildStart(
    size: size,
    sha256: sha,
    targetId: targetIdForEnvironment(env),
    token: arm.token,
  );
  await link.sendBinaryRequest(target, [reqTypeOta, start.length, ...start]);
  await Future<void>.delayed(const Duration(seconds: 2));
  stdout.writeln('status: ${await client.remoteCli(target, 'ota status')}');
  await link.disconnect();
}
