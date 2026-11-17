import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  /// 'github' | 'import' — anything not 'github' is a local import.
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
/// only from an explicit download or an explicit .bin import.
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
