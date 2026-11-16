import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Pseudo-environment for a `.bin` whose name does not carry a build
/// environment (a custom build, or the file a node already runs). The image's
/// SHA-256 is its identity; the node's own reported target id is what an
/// update is armed for.
const customEnvironment = 'custom';

/// One image in the offline library.
class LibraryEntry {
  const LibraryEntry({
    required this.id,
    required this.fileName,
    required this.env,
    required this.version,
    required this.origin,
    required this.size,
    required this.sha256,
    required this.added,
  });

  /// sha256 of the image bytes (also the file stem).
  final String id;
  final String fileName;

  final String env;
  final String version;

  /// 'github' | 'import' | 'fieldpack'
  final String origin;

  final int size;
  final String sha256;
  final DateTime added;
}

/// Persistent local firmware library. Every entry is `<sha256>.bin` plus a
/// `<sha256>.json` sidecar with env/version/origin metadata. The app finds
/// delta bases by matching the node's reported running image SHA-256 (the
/// `OP_INFO` handshake), falling back to the `running=` version stamp; and
/// never uploads anything to this directory implicitly — images land here
/// only from an explicit download, import, or pack restore.
class FirmwareLibrary {
  FirmwareLibrary(this.directory);

  final Directory directory;

  /// `<appSupport>/ota_library`.
  static Future<FirmwareLibrary> open(Directory supportDir) async {
    final dir = Directory(p.join(supportDir.path, 'ota_library'));
    await dir.create(recursive: true);
    return FirmwareLibrary(dir);
  }

  Future<List<LibraryEntry>> list() async {
    final out = <LibraryEntry>[];
    if (!await directory.exists()) return out;
    await for (final file in directory.list()) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final entry = await _readEntry(file);
      if (entry != null) out.add(entry);
    }
    out.sort((a, b) => b.added.compareTo(a.added));
    return out;
  }

  /// Find the base image for a delta against a node whose running image hashes
  /// to [runningSha256] (the `OP_INFO` handshake's full SHA-256). A byte match
  /// is the identity, so the entry's environment does not matter: the same
  /// image is the same base either way. Returns null when the library holds no
  /// such image (the caller falls back to the version stamp, then to a full
  /// image).
  Future<LibraryEntry?> findBaseForSha(List<int> runningSha256) async {
    final id =
        runningSha256.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final entry in await list()) {
      if (entry.sha256 == id) return entry;
    }
    return null;
  }

  /// Find the base image for a delta against a node running [runningVersion]
  /// (the full `running=` stamp from `ota status`, e.g.
  /// `v1.18.0-r4-filter-d1ebd2f`). The version stamp is a weaker identity than
  /// [findBaseForSha]: two builds of one commit can carry the same stamp and
  /// still differ (the build date is embedded). A wrong guess is caught by the
  /// device SHA gate (err=4) — nothing boots; the operator retries full-image.
  /// Returns null when there is no confident base — the caller falls back
  /// to a full image.
  Future<LibraryEntry?> findBaseFor(
      {required String env, required String runningVersion}) async {
    for (final entry in await list()) {
      if (entry.env == env && entry.version == runningVersion) return entry;
    }
    return null;
  }

  Future<LibraryEntry> importBytes(
    Uint8List bytes, {
    required String env,
    required String version,
    required String origin,
    String? fileName,
  }) async {
    final sha = sha256.convert(bytes).toString();
    final name = fileName ?? '$env-$version.bin';
    final binFile = File(p.join(directory.path, '$sha.bin'));
    if (!await binFile.exists()) {
      await binFile.writeAsBytes(bytes, flush: true);
    }
    final entry = LibraryEntry(
      id: sha,
      fileName: name,
      env: env,
      version: version,
      origin: origin,
      size: bytes.length,
      sha256: sha,
      added: DateTime.now(),
    );
    await _writeEntry(entry);
    return entry;
  }

  Future<Uint8List> read(LibraryEntry entry) =>
      File(p.join(directory.path, '${entry.id}.bin')).readAsBytes();

  Future<void> delete(LibraryEntry entry) async {
    await _deleteQuietly(File(p.join(directory.path, '${entry.id}.bin')));
    await _deleteQuietly(File(p.join(directory.path, '${entry.id}.json')));
  }

  /// Delete every image for [env] older than [keep] newest entries.
  Future<int> pruneEnvironment(String env, {int keep = 3}) async {
    final entries = (await list()).where((e) => e.env == env).toList()
      ..sort((a, b) => b.added.compareTo(a.added));
    var removed = 0;
    for (var i = keep; i < entries.length; i++) {
      await delete(entries[i]);
      removed++;
    }
    return removed;
  }

  int get totalBytes {
    var total = 0;
    try {
      for (final f in directory.listSync()) {
        if (f is File) total += f.lengthSync();
      }
    } catch (_) {}
    return total;
  }

  // --- field pack (zip) export / import -----------------------------------

  /// A field pack is one zip with `images/<fileName>` + `catalog.json`, meant
  /// for preparing offline updates without connectivity.
  Future<Uint8List> exportPack({Iterable<LibraryEntry>? only}) async {
    final archive = Archive();
    final entries = (only ?? await list()).toList();
    final catalog = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final bytes = await read(entry);
      archive.addFile(
          ArchiveFile('images/${entry.fileName}', bytes.length, bytes));
      catalog.add({
        'fileName': entry.fileName,
        'env': entry.env,
        'version': entry.version,
        'origin': entry.origin,
        'size': entry.size,
        'sha256': entry.sha256,
        'added': entry.added.toIso8601String(),
      });
    }
    final indexJson = jsonEncode({'packVersion': 1, 'images': catalog});
    archive.addFile(ArchiveFile(
      'catalog.json',
      utf8.encode(indexJson).length,
      utf8.encode(indexJson),
    ));
    final zipped = ZipEncoder().encode(archive);
    return Uint8List.fromList(zipped);
  }

  /// Import a field pack. Every image's bytes are re-hashed and must match
  /// the catalog entry before it lands; corrupt entries are skipped and
  /// counted. Returns the number imported.
  Future<int> importPack(Uint8List zipBytes,
      {bool Function(LibraryEntry)? filter}) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    Map<String, dynamic>? catalog;
    final images = <String, Uint8List>{};
    for (final file in archive) {
      if (!file.isFile) continue;
      if (file.name == 'catalog.json') {
        catalog = jsonDecode(utf8.decode(file.content as List<int>))
            as Map<String, dynamic>;
      } else if (file.name.startsWith('images/')) {
        images[p.basename(file.name)] =
            Uint8List.fromList(file.content as List<int>);
      }
    }
    var imported = 0;
    final entries = (catalog?['images'] as List?) ?? const [];
    for (final e in entries.whereType<Map>()) {
      final fileName = e['fileName'] as String? ?? '';
      final bytes = images[fileName];
      if (bytes == null) continue;
      final expected = (e['sha256'] as String? ?? '').toLowerCase();
      final actual = sha256.convert(bytes).toString();
      if (expected.isEmpty || expected != actual) continue; // corrupt: skip
      final entry = LibraryEntry(
        id: actual,
        fileName: fileName,
        env: e['env'] as String? ?? 'unknown',
        version: e['version'] as String? ?? 'unknown',
        origin: 'fieldpack',
        size: bytes.length,
        sha256: actual,
        added: DateTime.tryParse(e['added'] as String? ?? '') ?? DateTime.now(),
      );
      if (filter != null && !filter(entry)) continue;
      final binFile = File(p.join(directory.path, '$actual.bin'));
      if (!await binFile.exists()) {
        await binFile.writeAsBytes(bytes, flush: true);
      }
      await _writeEntry(entry);
      imported++;
    }
    return imported;
  }

  // --- internals -----------------------------------------------------------

  Future<LibraryEntry?> _readEntry(File jsonFile) async {
    try {
      final e =
          jsonDecode(await jsonFile.readAsString()) as Map<String, dynamic>;
      final id = p.basenameWithoutExtension(jsonFile.path);
      final binFile = File(p.join(directory.path, '$id.bin'));
      if (!await binFile.exists()) return null; // orphaned sidecar
      return LibraryEntry(
        id: id,
        fileName: e['fileName'] as String? ?? '$id.bin',
        env: e['env'] as String? ?? 'unknown',
        version: e['version'] as String? ?? 'unknown',
        origin: e['origin'] as String? ?? 'unknown',
        size: (e['size'] as num?)?.toInt() ?? (await binFile.length()),
        sha256: e['sha256'] as String? ?? id,
        added: DateTime.tryParse(e['added'] as String? ?? '') ??
            (await binFile.lastModified()),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeEntry(LibraryEntry entry) async {
    final json = {
      'fileName': entry.fileName,
      'env': entry.env,
      'version': entry.version,
      'origin': entry.origin,
      'size': entry.size,
      'sha256': entry.sha256,
      'added': entry.added.toIso8601String(),
    };
    await File(p.join(directory.path, '${entry.id}.json'))
        .writeAsString(jsonEncode(json), flush: true);
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }
}
