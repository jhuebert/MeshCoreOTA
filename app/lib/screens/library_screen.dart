import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firmware_library.dart';
import '../services/github_source.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Offline library: what the app already carries, and how to move it (field
/// packs). Reachable from the main screen, so images can be downloaded or
/// imported before a session starts; every image here is a candidate delta
/// base or a full-image install.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _busy = false;
  String? _message;

  static final _mobile = Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final totalBytes =
        app.libraryEntries.fold<int>(0, (sum, e) => sum + e.size);

    return Scaffold(
      appBar: AppBar(title: const Text('Firmware library')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              'Images the app has downloaded or been given. When the running '
              'firmware on a node matches one of these (by its reported '
              'SHA-256), updates go out as a delta — only what changed.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
            ),
          ),
          const SectionHeader('Library'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '${app.libraryEntries.length} image(s) · '
              '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
              style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_message!,
                  style: const TextStyle(color: OtaTheme.ok, fontSize: 12)),
            ),
          ...app.libraryEntries.map(
            (entry) => Card(
              child: ListTile(
                leading: const Icon(Icons.memory, color: OtaTheme.accent),
                title: Text(
                  entry.fileName,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                subtitle: Text(
                  '${entry.env} · ${entry.version} · ${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB · '
                  '${entry.origin} · ${_date(entry.added)}',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
                ),
                onTap: _busy
                    ? null
                    : () async {
                        await app.selectLibraryEntryForUpdate(entry);
                        _setMessage(
                            'Selected ${entry.fileName} for the update');
                      },
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  icon: const Icon(Icons.more_vert, color: OtaTheme.textMuted),
                  onSelected: (value) async {
                    switch (value) {
                      case 'install':
                        await app.selectLibraryEntryForUpdate(entry);
                        _setMessage(
                            'Selected ${entry.fileName} for the update');
                        break;
                      case 'base':
                        await app.setBaseOverride(entry);
                        _setMessage('Delta base set to ${entry.fileName}');
                        break;
                      case 'delete':
                        await _delete(app, entry);
                        break;
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'install', child: Text('Use for the update')),
                    PopupMenuItem(
                        value: 'base', child: Text('Use as delta base')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ),
          ),
          const SectionHeader('Import / export'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importBin,
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Import a .bin firmware file'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importPack,
                  icon: const Icon(Icons.unarchive_outlined),
                  label: const Text('Import field pack (.zip)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed:
                      _busy || app.libraryEntries.isEmpty ? null : _exportPack,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('Export field pack (.zip)'),
                ),
              ],
            ),
          ),
          const SectionHeader('Prepare for the field'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Working with no signal? Download the target release (and the '
              'release below it, as a delta base) on Wi-Fi before you leave. '
              'Both stay in the library and verify against your USB flash.\n\n'
              'A custom build is fine too: import its .bin and use the node\'s '
              'own reported board id, or pick the board on the firmware screen.',
              style: TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _delete(AppState app, LibraryEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete image?'),
        content: Text('${entry.fileName}\n\nThis cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    await app.library!.delete(entry);
    await app.refreshLibrary();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _importBin() async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final path = await _pickFile('bin');
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final parsed = FirmwareAsset.parse(
        name: fileName,
        size: bytes.length,
        downloadUrl: '',
      );
      final entry = await app.importLocalImage(
        bytes,
        fileName: fileName,
        env: parsed?.env,
        version: parsed?.version,
      );
      await app.refreshLibrary();
      _setMessage(parsed == null
          ? 'Imported $fileName as a custom image (env "${entry.env}")'
          : 'Imported ${parsed.env} ${parsed.displayVersion}');
    } catch (e) {
      _setMessage('Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importPack() async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final path = await _pickFile('zip');
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      final count = await app.library!.importPack(bytes);
      await app.refreshLibrary();
      _setMessage('Imported $count image(s) from the field pack');
    } catch (e) {
      _setMessage('Pack import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportPack() async {
    final app = context.read<AppState>();
    setState(() => _busy = true);
    try {
      final bytes = await app.library!.exportPack();
      await _saveFile(bytes, 'meshcoreota-fieldpack.zip');
      _setMessage('Field pack exported');
    } catch (e) {
      _setMessage('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The platform's file picker. `flutter_file_dialog` is the Android/iOS
  /// document picker; desktop (Linux/Windows/macOS) uses `file_selector`.
  Future<String?> _pickFile(String extension) async {
    if (_mobile) {
      return FlutterFileDialog.pickFile(
        params: OpenFileDialogParams(
          dialogType: OpenFileDialogType.document,
          fileExtensionsFilter: [extension],
        ),
      );
    }
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
    ]);
    return file?.path;
  }

  Future<void> _saveFile(List<int> bytes, String fileName) async {
    if (_mobile) {
      await FlutterFileDialog.saveFile(
        params: SaveFileDialogParams(
          data: Uint8List.fromList(bytes),
          fileName: fileName,
          mimeTypesFilter: const ['application/zip'],
        ),
      );
      return;
    }
    final location = await getSaveLocation(suggestedName: fileName);
    if (location == null) return;
    await File(location.path).writeAsBytes(bytes, flush: true);
  }

  void _setMessage(String message) {
    if (mounted) setState(() => _message = message);
  }
}
