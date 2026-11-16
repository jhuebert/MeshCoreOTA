import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_ota/services/firmware_library.dart';

Uint8List _bytes(int seed, int length) => Uint8List.fromList(
    List<int>.generate(length, (i) => (i * seed + 11) & 0xFF));

void main() {
  late Directory dir;
  late FirmwareLibrary library;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('library_test');
    library = FirmwareLibrary(dir);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('import, list, read and delete roundtrip', () async {
    final image = _bytes(3, 5000);
    final entry = await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4-filter-d1ebd2f',
      origin: 'github',
      fileName: 'Xiao_S3_WIO_repeater-v1.18.0-r4-filter-d1ebd2f.bin',
    );
    expect(entry.size, image.length);
    expect(entry.sha256, sha256.convert(image).toString());

    final entries = await library.list();
    expect(entries, hasLength(1));
    expect(entries.single.env, 'Xiao_S3_WIO_repeater');
    expect(entries.single.version, 'v1.18.0-r4-filter-d1ebd2f');

    final restored = await library.read(entries.single);
    expect(restored, image);

    await library.delete(entries.single);
    expect(await library.list(), isEmpty);
  });

  test('findBaseFor matches env + version stamp exactly', () async {
    final image = _bytes(5, 4000);
    await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4-filter-d1ebd2f',
      origin: 'github',
      fileName: 'x.bin',
    );
    final hit = await library.findBaseFor(
      env: 'Xiao_S3_WIO_repeater',
      runningVersion: 'v1.18.0-r4-filter-d1ebd2f',
    );
    expect(hit, isNotNull);

    expect(
      await library.findBaseFor(
          env: 'Xiao_S3_WIO_repeater',
          runningVersion: 'v1.18.0-dev.7-filter-aaaaaaa'),
      isNull,
    );
    expect(
      await library.findBaseFor(
          env: 'RAK_4631_repeater',
          runningVersion: 'v1.18.0-r4-filter-d1ebd2f'),
      isNull,
    );
  });

  test('findBaseForSha matches the running image by exact bytes', () async {
    final image = _bytes(7, 3000);
    final entry = await library.importBytes(
      image,
      env: 'Xiao_S3_WIO_repeater_observer',
      version: 'v1.18.0-r4-filter-d1ebd2f',
      origin: 'github',
      fileName: 'x.bin',
    );
    final hit = await library.findBaseForSha(sha256.convert(image).bytes);
    expect(hit, isNotNull);
    expect(hit!.id, entry.id);
    // An image the library does not hold is no base at all.
    expect(await library.findBaseForSha(sha256.convert(_bytes(9, 8)).bytes),
        isNull);
  });

  test('field pack roundtrip preserves entries', () async {
    final first = await library.importBytes(
      _bytes(7, 3000),
      env: 'Xiao_S3_WIO_repeater',
      version: 'v1.18.0-r4-filter-d1ebd2f',
      origin: 'github',
      fileName: 'xiao.bin',
    );
    final second = await library.importBytes(
      _bytes(9, 3100),
      env: 'RAK_4631_repeater',
      version: 'v1.18.0-dev.7-filter-0e03f87e',
      origin: 'github',
      fileName: 'rak.bin',
    );

    final pack = await library.exportPack();

    final otherDir = await Directory.systemTemp.createTemp('library_restore');
    final restore = FirmwareLibrary(otherDir);
    final imported = await restore.importPack(pack);
    expect(imported, 2);
    final entries = await restore.list();
    expect(
        entries.map((e) => e.fileName), containsAll(['xiao.bin', 'rak.bin']));
    expect(
      entries.firstWhere((e) => e.fileName == 'xiao.bin').version,
      first.version,
    );
    expect(
      entries.firstWhere((e) => e.fileName == 'rak.bin').version,
      second.version,
    );
    expect(
      await restore.read(entries.firstWhere((e) => e.fileName == 'xiao.bin')),
      _bytes(7, 3000),
    );
    await otherDir.delete(recursive: true);
  });

  test('importPack skips a per-entry hash mismatch silently', () async {
    // Pack with a catalog whose recorded sha does not match the bundled
    // image bytes — the entry must be skipped, the rest must import.
    final goodImage = _bytes(13, 2000);
    final badImage = _bytes(17, 2000);
    final expected = await library.importBytes(
      goodImage,
      env: 'x',
      version: 'v1.0.0-filter-0000001',
      origin: 'github',
      fileName: 'x.bin',
    );
    final archive = Archive();
    final catalogJson = jsonEncode({
      'packVersion': 1,
      'images': [
        {
          'fileName': 'good.bin',
          'env': 'x',
          'version': 'v1.0.0-filter-good001',
          'origin': 'github',
          'size': goodImage.length,
          'sha256': expected.sha256,
          'added': DateTime.now().toIso8601String(),
        },
        {
          'fileName': 'bad.bin',
          'env': 'x',
          'version': 'v1.0.0-filter-bad0001',
          'origin': 'github',
          'size': badImage.length,
          'sha256': 'deadbeef' * 8, // not the actual digest
          'added': DateTime.now().toIso8601String(),
        },
      ],
    });
    archive
        .addFile(ArchiveFile('images/good.bin', goodImage.length, goodImage));
    archive.addFile(ArchiveFile('images/bad.bin', badImage.length, badImage));
    archive.addFile(ArchiveFile(
      'catalog.json',
      utf8.encode(catalogJson).length,
      utf8.encode(catalogJson),
    ));
    final pack = Uint8List.fromList(ZipEncoder().encode(archive));

    final dest = await Directory.systemTemp.createTemp('library_skip');
    final restore = FirmwareLibrary(dest);
    final imported = await restore.importPack(pack);
    expect(imported, 1);
    final entries = await restore.list();
    expect(entries.single.fileName, 'good.bin');
    await dest.delete(recursive: true);
  });
}
