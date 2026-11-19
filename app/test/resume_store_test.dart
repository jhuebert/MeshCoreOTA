import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_ota/services/radio_plan.dart';
import 'package:meshcore_ota/services/resume_store.dart';

ResumePlan _plan({
  List<Uint8List>? frames,
  LoRaPreset? preset,
  String transport = 'tcp',
  String? ble,
}) =>
    ResumePlan(
      createdAt: 1732000000000,
      targetPublicKeyHex: 'aabbccdd',
      targetName: 'XiaoS3 Repeater',
      imageSha256: '1122334455',
      imageSize: 1441536,
      version: 'v1.18.0-r4',
      targetId: 0xba7783f9,
      runningSha256: 'caaed5f9',
      frames: frames ??
          <Uint8List>[
            Uint8List.fromList([0x4f, 0x54, 0x03, 1, 0, 9, 9]),
            Uint8List.fromList([0x4f, 0x54, 0x0d, 2, 0, 7, 7]),
          ],
      radioMode: RadioMode.tempRadio.index,
      radioPreset: preset ??
          const LoRaPreset(
              frequencyHz: 926000000,
              bandwidthHz: 500000,
              spreadingFactor: 7,
              codingRate: 5),
      radioDurationMinutes: 20,
      enabledRadio2ForUpdate: true,
      manualRoutePath: 'c0ff, c0c0',
      transportKind: transport,
      tcpHost: '192.168.1.165',
      tcpPort: 5000,
      bleDeviceId: ble,
      nextExpected: 42,
    );

void main() {
  late Directory dir;
  late ResumeStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('resume_store_test');
    store = ResumeStore(File('${dir.path}/ota_resume.bin'));
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('frames and metadata survive an encode/decode round trip', () {
    final plan = _plan(ble: 'AA:BB:CC:DD:EE:FF');
    final decoded = ResumeStore.decode(ResumeStore.encode(plan));

    expect(decoded, isNotNull);
    expect(decoded!.targetPublicKeyHex, plan.targetPublicKeyHex);
    expect(decoded.targetName, 'XiaoS3 Repeater');
    expect(decoded.imageSha256, plan.imageSha256);
    expect(decoded.imageSize, 1441536);
    expect(decoded.version, plan.version);
    expect(decoded.targetId, plan.targetId);
    expect(decoded.runningSha256, plan.runningSha256);
    expect(decoded.frames.length, 2);
    expect(decoded.frames.first, plan.frames.first);
    expect(decoded.frames.last, plan.frames.last);
    expect(decoded.radioMode, RadioMode.tempRadio.index);
    expect(decoded.radioPreset?.frequencyHz, 926000000);
    expect(decoded.radioPreset?.bandwidthHz, 500000);
    expect(decoded.radioPreset?.spreadingFactor, 7);
    expect(decoded.radioPreset?.codingRate, 5);
    expect(decoded.radioDurationMinutes, 20);
    expect(decoded.enabledRadio2ForUpdate, isTrue);
    expect(decoded.manualRoutePath, 'c0ff, c0c0');
    expect(decoded.transportKind, 'tcp');
    expect(decoded.tcpHost, '192.168.1.165');
    expect(decoded.tcpPort, 5000);
    expect(decoded.bleDeviceId, 'AA:BB:CC:DD:EE:FF');
    expect(decoded.nextExpected, 42);
    expect(decoded.createdAt, plan.createdAt);
  });

  test('empty frame list, no preset and BLE transport round trip', () {
    final base = _plan(frames: const [], transport: 'ble', ble: '11:22:33');
    final plan = ResumePlan(
      createdAt: base.createdAt,
      targetPublicKeyHex: base.targetPublicKeyHex,
      targetName: base.targetName,
      imageSha256: base.imageSha256,
      imageSize: base.imageSize,
      version: base.version,
      targetId: base.targetId,
      runningSha256: base.runningSha256,
      frames: const [],
      radioMode: base.radioMode,
      radioPreset: null,
      radioDurationMinutes: base.radioDurationMinutes,
      enabledRadio2ForUpdate: base.enabledRadio2ForUpdate,
      manualRoutePath: base.manualRoutePath,
      transportKind: base.transportKind,
      tcpHost: base.tcpHost,
      tcpPort: base.tcpPort,
      bleDeviceId: base.bleDeviceId,
      nextExpected: base.nextExpected,
    );
    final decoded = ResumeStore.decode(ResumeStore.encode(plan));
    expect(decoded, isNotNull);
    expect(decoded!.frames, isEmpty);
    expect(decoded.radioPreset, isNull);
    expect(decoded.transportKind, 'ble');
    expect(decoded.bleDeviceId, '11:22:33');
    expect(decoded.targetName, plan.targetName);
    expect(decoded.version, plan.version);
  });

  test('save writes atomically and load reads it back', () async {
    await store.save(_plan());
    expect(await File('${dir.path}/ota_resume.bin.tmp').exists(), isFalse);
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.frames.length, 2);
    expect(loaded.version, 'v1.18.0-r4');
  });

  test('load returns null when there is no file', () async {
    expect(await store.load(), isNull);
  });

  test('load drops a corrupt file', () async {
    await File('${dir.path}/ota_resume.bin').writeAsBytes([1, 2, 3]);
    expect(await store.load(), isNull);
    expect(await File('${dir.path}/ota_resume.bin').exists(), isFalse);
  });

  test('clear removes the saved file', () async {
    await store.save(_plan());
    await store.clear();
    expect(await File('${dir.path}/ota_resume.bin').exists(), isFalse);
  });

  test('decode rejects malformed containers', () {
    expect(ResumeStore.decode([1, 2, 3]), isNull);
    final good = ResumeStore.encode(_plan());
    final badMagic = Uint8List.fromList(good);
    badMagic[0] = 0;
    expect(ResumeStore.decode(badMagic), isNull);
    final badFormat = Uint8List.fromList(good);
    ByteData.sublistView(badFormat).setUint32(4, 99, Endian.little);
    expect(ResumeStore.decode(badFormat), isNull);
    final badMetaLen = Uint8List.fromList(good);
    ByteData.sublistView(badMetaLen).setUint32(8, 0x7fffffff, Endian.little);
    expect(ResumeStore.decode(badMetaLen), isNull);
    expect(ResumeStore.decode(good.sublist(0, good.length - 1)), isNull);
    expect(ResumeStore.decode(Uint8List.fromList([...good, 0x00])), isNull);
  });

  test('decode rejects a frame count that does not fit', () {
    final good = ResumeStore.encode(_plan());
    final bad = Uint8List.fromList(good);
    // Frame count sits just after the metadata: find it from the metadata
    // length, then write a count larger than the remaining bytes.
    final metaLen = bad.buffer.asByteData().getUint32(8, Endian.little);
    bad.buffer.asByteData().setUint32(12 + metaLen, 99999, Endian.little);
    expect(ResumeStore.decode(bad), isNull);
  });

  test('decode rejects an unreasonable frame count and malformed JSON', () {
    final good = ResumeStore.encode(_plan());
    final huge = Uint8List.fromList(good);
    final metaLen = huge.buffer.asByteData().getUint32(8, Endian.little);
    huge.buffer.asByteData().setUint32(12 + metaLen, 100001, Endian.little);
    expect(ResumeStore.decode(huge), isNull);

    final broken = Uint8List.fromList(good);
    broken[12] = 0xFF;
    expect(ResumeStore.decode(broken), isNull);
  });

  test('decode rejects malformed metadata', () {
    // Build valid containers with one metadata field broken.
    ResumePlan? decodeChanged(Map<String, dynamic> changes) {
      final json = _plan().toJson();
      json.addAll(changes);
      final meta = utf8.encode(jsonEncode(json));
      final raw = Uint8List(12 + meta.length + 4 + 2);
      void setByte(int i, int v) => raw[i] = v;
      for (var i = 0; i < 4; i++) {
        setByte(i, [0x4d, 0x43, 0x52, 0x4d][i]);
      }
      final bd = ByteData.sublistView(raw);
      bd.setUint32(4, ResumePlan.format, Endian.little);
      bd.setUint32(8, meta.length, Endian.little);
      for (var i = 0; i < meta.length; i++) {
        setByte(12 + i, meta[i]);
      }
      bd.setUint32(12 + meta.length, 0, Endian.little);
      return ResumeStore.decode(raw);
    }

    expect(decodeChanged({'v': 99}), isNull);
    expect(decodeChanged({'preset': 'nope'}), isNull);
    expect(
        decodeChanged({
          'preset': {'f': 'x'}
        }),
        isNull);
    expect(decodeChanged({'size': 'big'}), isNull);
    expect(decodeChanged({'next': null}), isNull);
    expect(decodeChanged({'pub': 42}), isNull);
  });
}
