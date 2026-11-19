import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

import 'radio_plan.dart';

/// Everything needed to carry on an update after the app dies.
///
/// The frames are the exact op stream the repeater was armed with. The node
/// applies ops strictly by sequence number and keeps its staged bytes in RAM
/// while it stays powered, so replaying the saved frames from the node's
/// `next_expected` sends only what is actually missing. Nothing here is a
/// secret: the admin password is session-only and is deliberately absent.
class ResumePlan {
  const ResumePlan({
    required this.createdAt,
    required this.targetPublicKeyHex,
    required this.targetName,
    required this.imageSha256,
    required this.imageSize,
    required this.version,
    required this.targetId,
    required this.runningSha256,
    required this.frames,
    required this.radioMode,
    required this.radioPreset,
    required this.radioDurationMinutes,
    required this.enabledRadio2ForUpdate,
    required this.manualRoutePath,
    required this.transportKind,
    required this.tcpHost,
    required this.tcpPort,
    required this.bleDeviceId,
    this.nextExpected = 1,
    this.sessionId = 0,
  });

  final int createdAt;
  final String targetPublicKeyHex;
  final String targetName;
  final String imageSha256;
  final int imageSize;
  final String version;
  final int targetId;
  final String runningSha256;
  final List<Uint8List> frames;

  final int radioMode;
  final LoRaPreset? radioPreset;
  final int radioDurationMinutes;
  final bool enabledRadio2ForUpdate;
  final String manualRoutePath;

  final String transportKind;
  final String tcpHost;
  final int tcpPort;
  final String? bleDeviceId;

  /// Last known node watermark, for display before the node is asked again.
  final int nextExpected;

  /// Per-arm id from `OP_STATUS_REPORT`. Non-zero only on nodes with the
  /// structured status op; a mismatch on reconnect means the repeater itself
  /// restarted and the staged bytes are gone. Zero is the legacy value.
  final int sessionId;

  static const int format = 1;

  Map<String, dynamic> toJson() => {
        'v': format,
        'at': createdAt,
        'pub': targetPublicKeyHex,
        'name': targetName,
        'sha': imageSha256,
        'size': imageSize,
        'ver': version,
        'tid': targetId,
        'run': runningSha256,
        'mode': radioMode,
        'preset': radioPreset == null
            ? null
            : {
                'f': radioPreset!.frequencyHz,
                'b': radioPreset!.bandwidthHz,
                's': radioPreset!.spreadingFactor,
                'c': radioPreset!.codingRate,
              },
        'dur': radioDurationMinutes,
        'r2': enabledRadio2ForUpdate,
        'path': manualRoutePath,
        'tr': transportKind,
        'host': tcpHost,
        'port': tcpPort,
        'ble': bleDeviceId,
        'next': nextExpected,
        'sid': sessionId,
      };

  static ResumePlan? fromJson(
      Map<String, dynamic> json, List<Uint8List> frames) {
    if (json['v'] != format) return null;
    final preset = json['preset'];
    LoRaPreset? radioPreset;
    if (preset is Map<String, dynamic>) {
      final f = preset['f'];
      final b = preset['b'];
      final s = preset['s'];
      final c = preset['c'];
      if (f is! int || b is! int || s is! int || c is! int) return null;
      radioPreset = LoRaPreset(
          frequencyHz: f, bandwidthHz: b, spreadingFactor: s, codingRate: c);
    } else if (preset != null) {
      return null;
    }
    final at = json['at'];
    final size = json['size'];
    final tid = json['tid'];
    final port = json['port'];
    final mode = json['mode'];
    final dur = json['dur'];
    final next = json['next'];
    if (at is! int ||
        size is! int ||
        tid is! int ||
        port is! int ||
        mode is! int ||
        dur is! int) {
      return null;
    }
    if (next is! int) return null;
    final sid = json['sid'];
    final sessionId = sid is int ? sid : 0; // old records had no session id
    String? str(String key) => json[key] is String ? json[key] as String : null;
    final pub = str('pub');
    final sha = str('sha');
    if (pub == null || sha == null) return null;
    return ResumePlan(
      createdAt: at,
      targetPublicKeyHex: pub,
      targetName: str('name') ?? '',
      imageSha256: sha,
      imageSize: size,
      version: str('ver') ?? '',
      targetId: tid,
      runningSha256: str('run') ?? '',
      frames: frames,
      radioMode: mode,
      radioPreset: radioPreset,
      radioDurationMinutes: dur,
      enabledRadio2ForUpdate: json['r2'] == true,
      manualRoutePath: str('path') ?? '',
      transportKind: str('tr') ?? 'tcp',
      tcpHost: str('host') ?? '127.0.0.1',
      tcpPort: port,
      bleDeviceId: str('ble'),
      nextExpected: next,
      sessionId: sessionId,
    );
  }
}

/// Atomic read/write of one [ResumePlan] file. A corrupt or unknown-format
/// file is dropped rather than allowed to block the app: it is only a
/// convenience for recovering an upload, never the firmware library itself.
class ResumeStore {
  ResumeStore(this.file);

  final File file;

  static final Uint8List _magic = Uint8List.fromList([0x4D, 0x43, 0x52, 0x4D]);
  static const int _maxMeta = 1 << 20;
  static const int _maxFrames = 100000;

  Future<ResumePlan?> load() async {
    Uint8List bytes;
    try {
      if (!await file.exists()) return null;
      bytes = await file.readAsBytes();
    } catch (_) {
      return null;
    }
    final plan = decode(bytes);
    if (plan == null) {
      await clear();
    }
    return plan;
  }

  Future<void> save(ResumePlan plan) async {
    final bytes = encode(plan);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A stale record is harmless — a later save replaces it.
    }
  }

  static Uint8List encode(ResumePlan plan) {
    final meta = utf8.encode(jsonEncode(plan.toJson()));
    final size = 4 +
        4 +
        4 +
        meta.length +
        4 +
        plan.frames.fold<int>(0, (n, f) => n + 2 + f.length);
    final bytes = ByteData(size);
    var at = 0;
    for (final b in _magic) {
      bytes.setUint8(at++, b);
    }
    bytes.setUint32(at, ResumePlan.format, Endian.little);
    at += 4;
    bytes.setUint32(at, meta.length, Endian.little);
    at += 4;
    for (final b in meta) {
      bytes.setUint8(at++, b);
    }
    bytes.setUint32(at, plan.frames.length, Endian.little);
    at += 4;
    for (final frame in plan.frames) {
      bytes.setUint16(at, frame.length, Endian.little);
      at += 2;
      for (final b in frame) {
        bytes.setUint8(at++, b);
      }
    }
    return bytes.buffer.asUint8List();
  }

  static ResumePlan? decode(List<int> input) {
    try {
      final raw = Uint8List.fromList(input);
      final bytes = ByteData.sublistView(raw);
      if (raw.length < 16) return null;
      for (var i = 0; i < _magic.length; i++) {
        if (bytes.getUint8(i) != _magic[i]) return null;
      }
      if (bytes.getUint32(4, Endian.little) != ResumePlan.format) return null;
      final metaLen = bytes.getUint32(8, Endian.little);
      if (metaLen > _maxMeta || 12 + metaLen + 4 > bytes.lengthInBytes) {
        return null;
      }
      final decoded =
          jsonDecode(utf8.decode(Uint8List.sublistView(raw, 12, 12 + metaLen)));
      if (decoded is! Map<String, dynamic>) return null;
      var at = 12 + metaLen;
      final count = bytes.getUint32(at, Endian.little);
      at += 4;
      if (count > _maxFrames) return null;
      final frames = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        final len = bytes.getUint16(at, Endian.little);
        at += 2;
        if (at + len > bytes.lengthInBytes) return null;
        frames
            .add(Uint8List.fromList(Uint8List.sublistView(raw, at, at + len)));
        at += len;
      }
      if (at != bytes.lengthInBytes) return null;
      return ResumePlan.fromJson(decoded, frames);
    } catch (_) {
      return null;
    }
  }
}
