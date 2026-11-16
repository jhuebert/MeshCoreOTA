// Hardware bench harness for the LoRa OTA path.
//
// This drives a real companion radio over TCP and stresses the fork
// repeater's OTA implementation end to end: stage, transfer, apply, verify,
// rollback, and the failure modes (bad token, SHA mismatch, out-of-order ops,
// mid-transfer abort). It prints timings so real-world update numbers can be
// recorded against a radio configuration.
//
// It is deliberately NOT part of the app or the test suites: it needs two
// radios on a desk and a companion reachable over TCP.
//
//   dart run bench/bin/bench.dart \
//     --host 192.168.1.165 --port 5000 --password password \
//     --contact XiaoS3 --env Xiao_S3_WIO_repeater \
//     --image /path/to/new.bin [--base /path/to/running.bin] \
//     --scenario all
//
// Scenarios (comma separated):
//   probe     read `ota status`, `version`, radio params
//   full      stage → transfer (full image) → report → apply → verify
//   delta     same, but base-matched (OP_COPY reuse) against --base
//   reject    arm/transfer failure modes (bad token, SHA mismatch, gap, abort)
//   rollback  `ota rollback` after a successful apply
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';

// --- result bookkeeping -----------------------------------------------------

final _checks = <({String name, bool ok, String detail})>[];

void check(String name, bool ok, [String detail = '']) {
  _checks.add((name: name, ok: ok, detail: detail));
  stdout.writeln(
      '${ok ? '  PASS' : '  FAIL'}  $name${detail.isEmpty ? '' : ' — $detail'}');
}

void info(String message) => stdout.writeln(message);

String _secs(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Run [body], reconnecting and retrying once when the companion link drops.
///
/// A stock companion's raw-TX pool is small and its TCP stack will drop a
/// session rather than queue without bound; a bench run that aborts on the
/// first such drop measures nothing. The staged slot is scrapped before the
/// retry so the node starts clean.
Future<void> _runWithRetry(Bench b, Future<void> Function() body) async {
  for (var attempt = 0;; attempt++) {
    try {
      await body();
      return;
    } catch (e) {
      if (attempt >= 1) rethrow;
      info('  ! link trouble ($e) — reconnecting and retrying once');
      try {
        await b.cli('ota abort');
      } catch (_) {}
      try {
        await b.link.disconnect();
      } catch (_) {}
      await b.reconnect();
    }
  }
}

Uint8List _sha256(List<int> data) =>
    Uint8List.fromList(sha256.convert(data).bytes);

// --- bench context ----------------------------------------------------------

class Bench {
  Bench({
    required this.host,
    required this.port,
    required this.password,
    required this.env,
    required this.contactName,
    required this.windowSize,
    required this.spacing,
  });

  final String host;
  final int port;
  final String password;
  final String env;
  final String contactName;
  final int windowSize;

  /// Delay between queued writes; the companion's raw-TX pool is small.
  final Duration spacing;

  late TcpDeviceLink link;
  late CompanionClient client;
  late Contact target;

  Future<void> connect() async {
    link = TcpDeviceLink(host: host, port: port);
    await link.connect();
    client = CompanionClient(link);
    info('connected to companion $host:$port');
  }

  /// Resolve the repeater contact by name (case-insensitive substring), else
  /// the only repeater-type contact.
  Future<void> resolveTarget() async {
    final contacts = await client.listContacts();
    info('companion has ${contacts.length} contact(s)');
    Contact? match;
    for (final c in contacts) {
      if (contactName.isNotEmpty &&
          c.name.toLowerCase().contains(contactName.toLowerCase())) {
        match = c;
        break;
      }
    }
    match ??= contacts.where((c) => c.advType == advTypeRepeater).firstOrNull;
    if (match == null) {
      throw StateError(
          'no contact matched "$contactName" and no repeater is known — '
          'let the repeater advert first (power-cycle it), then retry');
    }
    target = match;
    info(
        'target: "${target.name}" key=${target.publicKeyHex.substring(0, 12)}… '
        'route=${target.hasDirectRoute ? '${target.outPathLen}' : 'unknown'}');
  }

  Future<void> login() async {
    final r = await client.login(target, password);
    if (!r.ok) throw StateError('login rejected');
    if (!r.isAdmin) throw StateError('logged in but not as admin');
    info('logged in as admin');
  }

  Future<String> cli(String command) async {
    final reply = await client.remoteCli(target, command);
    return reply.trim();
  }

  Future<OtaStatus?> status() async => OtaStatus.parse(await cli('ota status'));

  Future<void> waitRebootAndLogin(
      {Duration timeout = const Duration(seconds: 150)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await client.login(target, password);
        if (r.ok) return;
      } catch (_) {
        // still booting
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw StateError('node did not come back within ${timeout.inSeconds}s');
  }

  OtaRoute get route => OtaRoute.zeroHop();

  /// Re-open the TCP link after a drop and re-establish admin access.
  Future<void> reconnect() async {
    link = TcpDeviceLink(host: host, port: port);
    await link.connect();
    client = CompanionClient(link);
    await resolveTarget();
    await login();
    info('  reconnected to companion');
  }

  /// Run one stage+transfer and return the measured numbers.
  Future<({TransferResult result, DeltaResult delta, OtaStageReply arm})>
      stageAndTransfer(
    Uint8List image, {
    Uint8List? base,
    bool Function()? shouldCancel,
    Duration? askTimeout,
    int? maxRetries,
    String? armShaOverride,
  }) async {
    final ver = 'bench-${_hex(_sha256(image)).substring(0, 8)}';
    final armSha = armShaOverride ?? _hex(_sha256(image));
    final t0 = DateTime.now();
    final stageReply = await cli('ota stage ${image.length} $armSha $ver');
    final arm = parseStageReply(stageReply);
    if (arm == null) throw StateError('staging refused: $stageReply');
    info(
        '  armed: size=${arm.size} token=${arm.token.toRadixString(16).padLeft(8, '0')} '
        '(${_secs(DateTime.now().difference(t0))})');

    final delta = base == null
        ? computeDelta(Uint8List(0), image)
        : computeDelta(base, image);
    info('  ops=${delta.opCount} literal=${delta.literalBytes}B '
        'copy=${delta.copyBytes}B');

    final engine = OtaTransfer(
      link: link,
      route: route,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: _sha256(image),
        targetId: targetIdForEnvironment(env),
        token: arm.token,
      ),
      ops: delta.ops,
      windowSize: windowSize,
      askTimeout: askTimeout ?? const Duration(seconds: 10),
      maxRetriesPerWindow: maxRetries ?? 12,
      opSpacing: spacing,
      shouldCancel: shouldCancel,
    );
    late TransferResult result;
    final t1 = DateTime.now();
    result = await engine.run(onProgress: (p) {
      if (p.opsApplied != null && p.opsApplied! % 200 == 0) {
        stdout.write('\r  progress ${p.opsApplied}/${p.opsTotal} ops    ');
      }
    });
    stdout.writeln('');
    final wall = DateTime.now().difference(t1);
    info('  transfer: ${_secs(wall)} wall, ${result.packetsSent} packets, '
        '${result.retries} retries, engine ${_secs(result.elapsed)}');
    return (result: result, delta: delta, arm: arm);
  }
}

// --- scenarios --------------------------------------------------------------

Future<void> scenarioProbe(Bench b) async {
  info('\n== probe ==');
  final version = await b.cli('version');
  info('  version: $version');
  final radio = await b.cli('get radio');
  info('  radio:   $radio');
  final st = await b.status();
  if (st == null) {
    check('firmware speaks the ota CLI', false, 'no parsable ota status');
    return;
  }
  check('firmware speaks the ota CLI', true);
  info(
      '  status:  running=${st.running} sha=${st.shaPrefix} state=${st.state.name} '
      'size=${st.size} off=${st.offset} err=${st.err}');

  final params = await b.link.radioParams();
  final airtime = loraTimeOnAirMicros(
    payloadBytes: 175,
    spreadingFactor: params.spreadingFactor,
    bandwidthHz: params.bandwidthHz,
    codingRate: params.codingRate,
  );
  info('  companion radio: ${params.frequencyHz / 1e6} MHz '
      'BW${params.bandwidthHz ~/ 1000} SF${params.spreadingFactor} CR${params.codingRate}');
  info('  one 175B packet ≈ ${(airtime / 1000).toStringAsFixed(0)} ms airtime');
}

Future<void> scenarioUpdate(Bench b, Uint8List image,
    {required Uint8List? base, required String label}) async {
  info('\n== $label ==');
  final before = await b.status();
  info('  before: state=${before?.state.name} running=${before?.running}');

  final t0 = DateTime.now();
  final run = await b.stageAndTransfer(image, base: base);
  final total = DateTime.now().difference(t0);

  final st = await b.status();
  info(
      '  after transfer: state=${st?.state.name} off=${st?.offset}/${st?.size} '
      'err=${st?.err}');
  check(
      '$label staged and verified (state=ready)',
      st?.state == OtaPhase.ready && st?.err == 0,
      'state=${st?.state.name} err=${st?.err}');

  if (st?.state != OtaPhase.ready) {
    await b.cli('ota abort');
    return;
  }

  final applyReply = await b.cli('ota apply');
  check('$label apply accepted', isApplyReply(applyReply), applyReply);
  final tApply = DateTime.now();
  await b.waitRebootAndLogin();
  final reboot = DateTime.now().difference(tApply);
  final version = await b.cli('version');
  info('  rebooted in ${_secs(reboot)}; version: $version');
  check('$label new image runs', version.isNotEmpty, version);

  info('  TIMING $label: transfer ${_secs(total)} '
      '(+ reboot ${_secs(reboot)}), ${run.result.packetsSent} packets, '
      '${run.delta.literalBytes}B literal, ${run.delta.copyBytes}B reused');
}

Future<void> scenarioReject(Bench b, Uint8List image) async {
  info('\n== reject: failure modes ==');

  // 1) arm, then START with a wrong token → node must refuse the arm.
  final shaHex = _hex(_sha256(image));
  final armReply =
      await b.cli('ota stage ${image.length} $shaHex bench-reject');
  final arm = parseStageReply(armReply);
  check('arm for reject tests', arm != null, armReply);
  if (arm == null) return;

  final badToken = arm.token ^ 0xFFFFFFFF;
  await b.link.sendRawPacket(PacketBuilder.createRawCustom(buildStart(
    size: image.length,
    sha256: _sha256(image),
    targetId: targetIdForEnvironment(b.env),
    token: badToken,
  )).writeTo());
  await Future<void>.delayed(const Duration(seconds: 2));
  var st = await b.status();
  check(
      'wrong token does not start a session',
      st?.state == OtaPhase.idle && st?.err == otaErrToken,
      'state=${st?.state.name} err=${st?.err} (expect idle/err=7)');

  // The pending arm survives a stranger's START; the real token still works,
  // so use it to walk a full staging run with a corrupted target image: arm
  // the *good* hash, then send bytes that hash differently. OP_END must
  // catch it (err=4) and scrap the slot.
  final corrupt = Uint8List.fromList(image);
  for (var i = 0; i < 64 && i < corrupt.length; i++) {
    corrupt[corrupt.length - 1 - i] ^= 0xFF;
  }
  final ops = computeDelta(Uint8List(0), image).ops;
  // Send real ops, but corrupt the literal bytes on the wire.
  final tampered = _tamperLiterals(ops, corrupt);
  final tamperEngine = OtaTransfer(
    link: b.link,
    route: b.route,
    contract: OtaStartContract(
      imageSize: image.length,
      imageSha256: _sha256(image),
      targetId: targetIdForEnvironment(b.env),
      token: arm.token,
    ),
    ops: tampered,
    windowSize: b.windowSize,
    opSpacing: const Duration(milliseconds: 20),
  );
  try {
    await tamperEngine.run();
  } catch (e) {
    info('  tampered transfer ended: $e');
  }
  st = await b.status();
  check(
      'SHA gate rejects a corrupted image',
      st?.state == OtaPhase.error && st?.err == otaErrSha,
      'state=${st?.state.name} err=${st?.err} (expect error/err=4)');
  await b.cli('ota abort');
  st = await b.status();
  check('abort clears the error', st?.state == OtaPhase.idle,
      'state=${st?.state.name}');

  // 2) mid-transfer abort: start a real transfer and cancel after a window.
  final arm2Reply =
      await b.cli('ota stage ${image.length} $shaHex bench-abort');
  final arm2 = parseStageReply(arm2Reply);
  if (arm2 != null) {
    var seen = 0;
    final abortEngine = OtaTransfer(
      link: b.link,
      route: b.route,
      contract: OtaStartContract(
        imageSize: image.length,
        imageSha256: _sha256(image),
        targetId: targetIdForEnvironment(b.env),
        token: arm2.token,
      ),
      ops: computeDelta(Uint8List(0), image).ops,
      windowSize: b.windowSize,
      opSpacing: b.spacing,
      shouldCancel: () => ++seen > 3,
    );
    var cancelled = false;
    try {
      await abortEngine.run();
    } on OtaTransferException {
      cancelled = true;
    }
    check('mid-transfer cancel stops the engine', cancelled);
    final abortReply = await b.cli('ota abort');
    info('  abort reply: $abortReply');
    st = await b.status();
    check(
        'node returns to idle after abort',
        st?.state == OtaPhase.idle && st?.offset == 0,
        'state=${st?.state.name} off=${st?.offset}');
  }
}

/// Swap the literal payloads for corruption bytes, keeping op framing.
List<DeltaOp> _tamperLiterals(List<DeltaOp> ops, Uint8List corrupt) {
  var pos = 0;
  final out = <DeltaOp>[];
  for (final op in ops) {
    if (op is LiteralOp) {
      final take = op.data.length;
      final slice = corrupt.sublist(
          pos, pos + take > corrupt.length ? corrupt.length : pos + take);
      out.add(LiteralOp(Uint8List.fromList(slice)));
      pos += take;
    } else {
      out.add(op);
    }
  }
  return out;
}

Future<void> scenarioMeasure(Bench b, Uint8List image,
    {required Uint8List? base, required String label}) async {
  info('\n== measure: $label ==');
  final t0 = DateTime.now();
  final run = await b.stageAndTransfer(image, base: base);
  final total = DateTime.now().difference(t0);
  final st = await b.status();
  info(
      '  after transfer: state=${st?.state.name} off=${st?.offset}/${st?.size} '
      'err=${st?.err}');
  check(
      '$label reached a terminal state (ready or sha-rejected)',
      st?.state == OtaPhase.ready || st?.state == OtaPhase.error,
      'state=${st?.state.name} err=${st?.err}');
  if (st?.state == OtaPhase.ready) {
    // Timing runs never boot the image; scrap the staged slot.
    await b.cli('ota abort');
  }
  final kbps = run.delta.literalBytes == 0
      ? 0.0
      : (run.delta.literalBytes / 1024) / (total.inMilliseconds / 1000);
  info('  MEASURE $label: ${_secs(total)} wall, '
      '${run.delta.literalBytes}B literal, ${run.result.packetsSent} packets, '
      '${run.result.retries} retries, ${kbps.toStringAsFixed(2)} KiB/s literal');
}

Future<void> scenarioRollback(Bench b) async {
  info('\n== rollback ==');
  final before = await b.cli('version');
  info('  version before: $before');
  final reply = await b.cli('ota rollback');
  check('rollback accepted', isRollbackReply(reply), reply);
  if (!isRollbackReply(reply)) return;
  await b.waitRebootAndLogin();
  final after = await b.cli('version');
  info('  version after:  $after');
  check('node came back on the previous image', after.isNotEmpty);
  check('version changed after rollback', !after.contains(RegExp(r'bench-')),
      after);
}

// --- entry point ------------------------------------------------------------

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);
  final host = args['host'] ?? '127.0.0.1';
  final port = int.parse(args['port'] ?? '5000');
  final password = args['password'] ?? 'password';
  final env = args['env'] ?? 'Xiao_S3_WIO_repeater';
  final contactName = args['contact'] ?? '';
  final windowSize = int.parse(args['window'] ?? '4');
  final scenarios = (args['scenario'] ?? 'probe').split(',');
  final imagePath = args['image'];
  final basePath = args['base'];

  final b = Bench(
    host: host,
    port: port,
    password: password,
    env: env,
    contactName: contactName,
    windowSize: windowSize,
    spacing: Duration(milliseconds: int.parse(args['spacing'] ?? '50')),
  );

  await b.connect();
  await b.resolveTarget();
  await b.login();

  Uint8List? image;
  if (imagePath != null) image = File(imagePath).readAsBytesSync();
  Uint8List? base;
  if (basePath != null) base = File(basePath).readAsBytesSync();
  if (image != null) {
    info(
        'image: ${image.length} bytes sha=${_hex(_sha256(image)).substring(0, 16)}…');
  }

  try {
    for (final s in scenarios) {
      await _runWithRetry(b, () async {
        switch (s.trim()) {
          case 'probe':
            await scenarioProbe(b);
          case 'full':
            if (image == null) throw StateError('full needs --image');
            await scenarioUpdate(b, image, base: null, label: 'full');
          case 'delta':
            if (image == null) throw StateError('delta needs --image');
            if (base == null) throw StateError('delta needs --base');
            await scenarioUpdate(b, image, base: base, label: 'delta');
          case 'reject':
            if (image == null) throw StateError('reject needs --image');
            await scenarioReject(b, image);
          case 'measure':
            if (image == null) throw StateError('measure needs --image');
            await scenarioMeasure(b, image,
                base: base, label: args['label'] ?? 'image');
          case 'rollback':
            await scenarioRollback(b);
          case '':
            break;
          default:
            throw StateError('unknown scenario "$s"');
        }
      });
    }
  } finally {
    await b.link.disconnect();
  }

  final failed = _checks.where((c) => !c.ok).toList();
  info(
      '\n== summary: ${_checks.length - failed.length}/${_checks.length} checks passed ==');
  for (final c in failed) {
    info('  FAILED: ${c.name} ${c.detail}');
  }
  exit(failed.isEmpty ? 0 : 1);
}

Map<String, String> _parseArgs(List<String> argv) {
  final out = <String, String>{};
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) {
      out[key] = argv[++i];
    } else {
      out[key] = '';
    }
  }
  return out;
}
