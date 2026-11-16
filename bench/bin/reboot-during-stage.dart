// Low-airtime reboot-during-staging test. Sends START + one LITERAL, reboots
// before OP_END, then verifies the node discarded the uncommitted OTA session.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

String _hex(List<int> b) =>
    b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();

Future<void> main() async {
  const host = '192.168.1.165';
  const name = 'XiaoS3 Repeater';
  const password = 'password';
  const env = 'Xiao_S3_WIO_repeater_observer';
  const totalSize = 4096;
  final image =
      Uint8List.fromList(List<int>.generate(totalSize, (i) => i & 0xff));
  final sha = Uint8List.fromList(sha256.convert(image).bytes);

  final link = TcpDeviceLink(host: host);
  await link.connect();
  final client = CompanionClient(link);
  final target =
      (await client.listContacts()).firstWhere((c) => c.name.contains(name));
  final login = await client.login(target, password);
  if (!login.ok || !login.isAdmin) throw StateError('admin login failed');
  stdout.writeln(
      'version before reboot: ${await client.remoteCli(target, 'version')}');
  final stage = await client.remoteCli(
      target, 'ota stage $totalSize ${_hex(sha)} reboot-interrupt');
  final arm = parseStageReply(stage);
  stdout.writeln('stage: $stage');
  if (arm == null) throw StateError('stage refused');

  final start = buildStart(
    size: totalSize,
    sha256: sha,
    targetId: targetIdForEnvironment(env),
    token: arm.token,
  );
  await link.sendBinaryRequest(target, [reqTypeOta, start.length, ...start]);
  final chunk = buildLiteralChunk(seq: 1, data: image.sublist(0, 128));
  await link.sendBinaryRequest(target, [reqTypeOta, chunk.length, ...chunk]);
  await Future<void>.delayed(const Duration(seconds: 1));
  stdout.writeln(
      'staged before reboot: ${await client.remoteCli(target, 'ota status')}');
  stdout.writeln('reboot: ${await client.remoteCli(target, 'reboot')}');
  await link.disconnect();

  // Reconnect, log in again (reboot clears the admin session), and check the
  // incomplete session was discarded without changing the running image.
  final retry = TcpDeviceLink(host: host);
  for (var attempt = 0; attempt < 30; attempt++) {
    try {
      await retry.connect();
      final c = CompanionClient(retry);
      final t =
          (await c.listContacts()).firstWhere((v) => v.name.contains(name));
      final l = await c.login(t, password);
      if (l.ok) {
        stdout.writeln(
            'version after reboot: ${await c.remoteCli(t, 'version')}');
        stdout.writeln(
            'status after reboot: ${await c.remoteCli(t, 'ota status')}');
        await retry.disconnect();
        return;
      }
    } catch (_) {
      try {
        await retry.disconnect();
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError('node did not return after staging reboot');
}
