import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firmware_library.dart';
import '../services/github_source.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'review_screen.dart';

/// Step 4: pick what to install — or the standalone library manager.
///
/// The same screen serves both contexts. Inside an update
/// ([updateMode] true) it is wizard step 4 and tapping an image selects it
/// for the update. From the main screen ([updateMode] false) it is a file
/// manager for the library: download GitHub release versions, import `.bin`
/// files, delete what is no longer needed — taps never select an update.
///
/// The GitHub listing is scoped to the board the node reported (all boards
/// when there is no node), and both release channels are tabs sorted
/// newest-first. Versions are saved for offline use whole (every board);
/// downloaded versions appear one row per version, imported `.bin` files one
/// row per file — separately, because they are different things.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key, this.updateMode = true});

  /// true: wizard step 4 (tapping picks the image). false: the standalone
  /// library manager reached from the main screen (taps download/inspect).
  final bool updateMode;

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      if (!app.offlineMode && app.catalog == null && !app.catalogLoading) {
        app.loadCatalog();
      }
      app.refreshLibrary();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  static final _mobile = Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final update = widget.updateMode;

    return Scaffold(
      appBar: AppBar(
        title: Text(update ? 'Choose firmware' : 'Firmware library'),
        actions: [
          IconButton(
            tooltip: app.offlineMode
                ? 'Offline — showing downloaded versions only. Tap to go online.'
                : 'Go offline — never contact GitHub',
            onPressed: () => app.setOfflineMode(!app.offlineMode),
            icon: Icon(
              app.offlineMode ? Icons.cloud_off : Icons.cloud_queue,
              color: app.offlineMode ? OtaTheme.warn : OtaTheme.textMuted,
            ),
          ),
          const SizedBox(width: 4),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: OtaTheme.accent,
          tabs: const [
            Tab(text: 'GitHub'),
            Tab(text: 'Offline'),
            Tab(text: 'Imported'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (update) const WizardBar(step: 4, label: 'Choose the image'),
          if (app.offlineMode)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: OtaTheme.warn.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: OtaTheme.warn.withValues(alpha: 0.35)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.cloud_off, color: OtaTheme.warn, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline — no GitHub requests. Versions saved on this '
                      'device are in the Offline tab.',
                      style: TextStyle(
                          color: OtaTheme.warn, fontSize: 12, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildGitHubTab(app),
                _buildOfflineTab(app),
                _buildImportedTab(app),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: update ? _buildSelectionBar(context, app) : null,
    );
  }

  // ---------------------------------------------------------------- GitHub

  Widget _buildGitHubTab(AppState app) {
    if (app.offlineMode) {
      return _offlineEmpty(
        icon: Icons.cloud_off,
        title: 'You are offline',
        body: 'The app is not contacting GitHub. Switch back online to browse '
            'releases and save a version for the field, or pick a version from '
            'the Offline tab.',
        action: FilledButton.icon(
          onPressed: () => app.setOfflineMode(false),
          icon: const Icon(Icons.cloud_queue),
          label: const Text('Go online'),
        ),
      );
    }

    final envs = app.knownEnvironments.toList()..sort();
    final releases = app.visibleReleases;
    final board = app.selectedBoard;
    final detected = app.detectedBoard;
    final update = widget.updateMode;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Board',
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: board ?? '',
                      isDense: true,
                      isExpanded: true,
                      items: [
                        const DropdownMenuItem(
                            value: '', child: Text('All boards')),
                        for (final env in envs)
                          DropdownMenuItem(value: env, child: Text(env)),
                      ],
                      onChanged: (value) => app.setSelectedBoard(
                          value == null || value.isEmpty ? null : value),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Refresh releases',
                onPressed: app.catalogLoading
                    ? null
                    : () => app.loadCatalog(forceRefresh: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            update
                ? (detected == null
                    ? (board == null
                        ? 'The node did not report a known board — pick one, or '
                            'import a custom .bin in the Imported tab.'
                        : 'Scoped to $board. The node did not report a board.')
                    : 'Detected from the node: $detected')
                : (board == null
                    ? 'Not connected to a node — showing every board. Pick one '
                        'to scope the list.'
                    : 'Showing images for $board only.'),
            style: const TextStyle(
                color: OtaTheme.textMuted, fontSize: 11, height: 1.35),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: SegmentedButton<ReleaseTrack>(
            segments: const [
              ButtonSegment(value: ReleaseTrack.stable, label: Text('Stable')),
              ButtonSegment(value: ReleaseTrack.dev, label: Text('Dev builds')),
            ],
            selected: {app.releaseTrack},
            onSelectionChanged: (s) => app.setReleaseTrack(s.first),
          ),
        ),
        if (app.catalogFromCache)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Showing the cached catalog (may be stale).',
              style: TextStyle(color: OtaTheme.textMuted, fontSize: 11),
            ),
          ),
        if (app.catalogError != null) ErrorBanner(app.catalogError!),
        if (app.catalogLoading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          Expanded(
            child: releases.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        board == null
                            ? 'No releases match this board.'
                            : 'No ${app.releaseTrack == ReleaseTrack.dev ? 'dev ' : ''}'
                                'releases with an image for $board.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: OtaTheme.textMuted),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      for (final release in releases)
                        _ReleaseSection(
                          release: release,
                          updateMode: widget.updateMode,
                        ),
                    ],
                  ),
          ),
      ],
    );
  }

  // --------------------------------------------------------------- Offline

  Widget _buildOfflineTab(AppState app) {
    final versions = app.offlineVersions;
    if (versions.isEmpty) {
      return _offlineEmpty(
        icon: Icons.cloud_download_outlined,
        title: 'No versions saved for offline use yet',
        body: 'On the GitHub tab, save a version with the download button. '
            'Every board\u2019s image for that version is stored on this device, '
            'so you can update in the field with no signal. Custom builds can '
            'be imported on the Imported tab — they work offline too.',
        action: app.offlineMode
            ? FilledButton.icon(
                onPressed: () => app.setOfflineMode(false),
                icon: const Icon(Icons.cloud_queue),
                label: const Text('Go online'),
              )
            : null,
      );
    }
    final totalBytes = versions.fold<int>(
        0, (sum, v) => sum + v.entries.fold<int>(0, (s, e) => s + e.size));
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${versions.length} version(s) on this device · '
            '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
            style: const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
          ),
        ),
        for (final version in versions)
          Card(
            child: ExpansionTile(
              leading: Icon(
                version.complete || !version.known
                    ? Icons.offline_pin
                    : Icons.rule,
                color: version.complete || !version.known
                    ? OtaTheme.ok
                    : OtaTheme.warn,
              ),
              title: Text(
                version.version,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${version.entries.length} image(s)'
                '${version.known ? (version.complete ? ' · complete version' : ' · partial') : ''}',
                style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
              ),
              children: [
                for (final entry in version.entries)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.memory,
                        color: OtaTheme.accent, size: 20),
                    title:
                        Text(entry.env, style: const TextStyle(fontSize: 12)),
                    subtitle: Text(
                      '${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB · '
                      '${entry.fileName}',
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 10.5),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.updateMode &&
                            identical(entry, app.selectedLibraryEntry))
                          const Icon(Icons.check, color: OtaTheme.accent),
                        IconButton(
                          tooltip: 'Delete ${entry.env}',
                          icon: const Icon(Icons.delete_outline,
                              color: OtaTheme.textMuted, size: 20),
                          onPressed: () => _deleteEntries(
                            app,
                            [entry],
                            title: 'Delete image?',
                            body: '${entry.fileName}\n\n'
                                'This cannot be undone.',
                          ),
                        ),
                      ],
                    ),
                    onTap: app.imageLoading
                        ? null
                        : () => widget.updateMode
                            ? app.selectLibraryEntryForUpdate(entry)
                            : _inspectEntry(entry),
                  ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.delete_outline,
                      color: OtaTheme.bad, size: 20),
                  title: Text(
                    'Delete this version',
                    style: const TextStyle(
                        color: OtaTheme.bad,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Removes all ${version.entries.length} image(s) — '
                    '${((version.entries.fold<int>(0, (s, e) => s + e.size)) / (1024 * 1024)).toStringAsFixed(1)} MB',
                    style: const TextStyle(
                        color: OtaTheme.textMuted, fontSize: 10.5),
                  ),
                  onTap: () => _deleteEntries(
                    app,
                    version.entries,
                    title: 'Delete ${version.version}?',
                    body: 'This removes all ${version.entries.length} image(s) '
                        'of ${version.version} from this device.\n\n'
                        'This cannot be undone.',
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------- Imported

  Widget _buildImportedTab(AppState app) {
    final entries = app.importedEntries;
    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.size);
    final update = widget.updateMode;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entries.isEmpty
                      ? 'No imported .bin files yet'
                      : '${entries.length} file(s) · '
                          '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: () => _importBin(app),
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Import a .bin'),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'Imported .bin files are custom or local builds. An '
                      'imported image is matched by its SHA-256 — the same '
                      'bytes are the same delta base or update image, whatever '
                      'its file name says.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 12),
                  children: [
                    for (final entry in entries)
                      Card(
                        color:
                            update && identical(entry, app.selectedLibraryEntry)
                                ? OtaTheme.surfaceHigh
                                : null,
                        child: ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.memory, color: OtaTheme.accent),
                          title: Text(entry.fileName,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                          subtitle: Text(
                            '${entry.env} · ${entry.version} · '
                            '${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB',
                            style: const TextStyle(
                                color: OtaTheme.textMuted, fontSize: 11),
                          ),
                          trailing: app.imageLoading &&
                                  identical(entry, app.selectedLibraryEntry)
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert,
                                      color: OtaTheme.textMuted),
                                  onSelected: (value) =>
                                      _importedMenuAction(app, entry, value),
                                  itemBuilder: (_) => update
                                      ? const [
                                          PopupMenuItem(
                                              value: 'install',
                                              child:
                                                  Text('Use for the update')),
                                          PopupMenuItem(
                                              value: 'base',
                                              child: Text('Use as delta base')),
                                          PopupMenuItem(
                                              value: 'details',
                                              child: Text('Details')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ]
                                      : const [
                                          PopupMenuItem(
                                              value: 'details',
                                              child: Text('Details')),
                                          PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete')),
                                        ],
                                ),
                          onTap: app.imageLoading
                              ? null
                              : () => update
                                  ? app.selectLibraryEntryForUpdate(entry)
                                  : _inspectEntry(entry),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _importedMenuAction(
      AppState app, LibraryEntry entry, String value) async {
    switch (value) {
      case 'install':
        await app.selectLibraryEntryForUpdate(entry);
      case 'base':
        await app.setBaseOverride(entry);
        _showSnack('Delta base set to ${entry.fileName}');
      case 'details':
        _inspectEntry(entry);
      case 'delete':
        await _deleteEntries(
          app,
          [entry],
          title: 'Delete image?',
          body: '${entry.fileName}\n\nThis cannot be undone.',
        );
    }
  }

  // -------------------------------------------------------------- actions

  Future<void> _importBin(AppState app) async {
    try {
      final path = await _pickBinFile();
      if (path == null) return;
      final bytes = await File(path).readAsBytes();
      final fileName = path.split(RegExp(r'[/\\]')).last;
      final parsed = FirmwareAsset.parse(
        name: fileName,
        size: bytes.length,
        downloadUrl: '',
      );
      await app.importLocalImage(
        bytes,
        fileName: fileName,
        env: parsed?.env,
        version: parsed?.version,
      );
      _showSnack(parsed == null
          ? 'Imported $fileName as a custom image'
          : 'Imported ${parsed.env} ${parsed.displayVersion}');
    } catch (e) {
      _showSnack('Import failed: $e');
    }
  }

  /// The platform's file picker. `flutter_file_dialog` is the Android/iOS
  /// document picker; desktop (Linux/Windows/macOS) uses `file_selector`.
  Future<String?> _pickBinFile() async {
    if (_mobile) {
      return FlutterFileDialog.pickFile(
        params: OpenFileDialogParams(
          dialogType: OpenFileDialogType.document,
          fileExtensionsFilter: const ['bin'],
        ),
      );
    }
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: 'BIN', extensions: const ['bin']),
    ]);
    return file?.path;
  }

  /// Confirm, delete, and report. The delta base and any selected image are
  /// repaired inside [AppState.deleteLibraryEntries].
  Future<void> _deleteEntries(
    AppState app,
    Iterable<LibraryEntry> entries, {
    required String title,
    required String body,
  }) async {
    final list = entries.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await app.deleteLibraryEntries(list);
    _showSnack(list.length == 1
        ? 'Deleted ${list.single.fileName}'
        : 'Deleted ${list.length} image(s)');
  }

  void _inspectEntry(LibraryEntry entry) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.fileName,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13, height: 1.4)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _inspectRow('Board', entry.env),
            _inspectRow('Version', entry.version),
            _inspectRow('Origin', entry.origin),
            _inspectRow('Size',
                '${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB'),
            _inspectRow('Added', _shortDate(entry.added)),
            const SizedBox(height: 8),
            const Text('SHA-256',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
            const SizedBox(height: 2),
            SelectableText(entry.sha256,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, height: 1.4)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _shortDate(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  Widget _inspectRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(label,
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 11)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _offlineEmpty({
    required IconData icon,
    required String title,
    required String body,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: OtaTheme.textMuted),
            const SizedBox(height: 12),
            Text(title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: OtaTheme.textMuted, fontSize: 12, height: 1.45),
            ),
            if (action != null) ...[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context, AppState app) {
    final package = app.selectedLibraryEntry ?? app.selectedAsset;
    final env = app.selectedEnvironment;
    final canTarget =
        (env != null && env != customEnvironment) || app.nodeInfo != null;
    final ready = app.selectedImage != null &&
        !app.imageLoading &&
        app.imageError == null &&
        canTarget;
    final detected = app.detectedBoard;
    final mismatch = env != null &&
        env != customEnvironment &&
        detected != null &&
        env != detected;

    return Material(
      color: OtaTheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (package != null && app.selectedImage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Selected: ${package is FirmwareAsset ? package.env : (package as LibraryEntry).env} · '
                  '${app.selectedDisplayVersion ?? '?'} · ${app.estimateLabel()}',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ),
            if (mismatch)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'This image is for $env, but the node reported $detected. '
                  'The node will refuse it at staging.',
                  style: const TextStyle(color: OtaTheme.warn, fontSize: 11),
                ),
              ),
            if (app.imageError != null)
              Text(
                app.imageError!,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            if (!ready && app.selectedImage != null && !canTarget)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'This image has no board name and the node did not answer the '
                  'capability handshake, so the target cannot be checked. '
                  'Import a build for a known board instead.',
                  style: TextStyle(color: OtaTheme.warn, fontSize: 11),
                ),
              ),
            FilledButton.icon(
              onPressed: ready
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ReviewScreen()),
                      )
                  : null,
              icon: app.imageLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1A1203),
                      ),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(app.imageLoading ? 'Downloading…' : 'Review update'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseSection extends StatelessWidget {
  const _ReleaseSection({required this.release, required this.updateMode});

  final FirmwareRelease release;
  final bool updateMode;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final images = release.appImages.where(app.assetMatchesBoard).toList()
      ..sort((a, b) => a.env.compareTo(b.env));
    if (images.isEmpty) return const SizedBox.shrink();
    final savedCount = release.appImages
        .where((a) => app.libraryEntryForAsset(a) != null)
        .length;
    final allSaved = savedCount == release.appImages.length;
    final downloading = app.downloadingReleaseTag == release.tag;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      release.tag,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                    Text(
                      _date(release.publishedAt),
                      style: const TextStyle(
                          color: OtaTheme.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              StatusPill(
                release.isDevTrack ? 'DEV' : 'STABLE',
                color: release.isDevTrack ? OtaTheme.warn : OtaTheme.ok,
              ),
              const SizedBox(width: 4),
              if (downloading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: app.releaseDownloadProgress,
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: allSaved
                      ? 'Saved for offline use'
                      : 'Save every image of this version for offline use',
                  onPressed: allSaved
                      ? null
                      : () async {
                          final saved =
                              await app.downloadReleaseToLibrary(release);
                          if (!context.mounted) return;
                          final complete = release.appImages.every(
                              (a) => app.libraryEntryForAsset(a) != null);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(saved == 0
                                  ? (complete
                                      ? '${release.tag} is already saved'
                                      : 'Nothing new to save for ${release.tag}')
                                  : 'Saved ${release.tag} — $saved image(s) for offline use'),
                            ),
                          );
                        },
                  icon: Icon(
                    allSaved
                        ? Icons.offline_pin
                        : Icons.cloud_download_outlined,
                    color: allSaved ? OtaTheme.ok : OtaTheme.accent,
                  ),
                ),
            ],
          ),
        ),
        ...images.map((asset) {
          final selected = app.selectedAsset?.name == asset.name;
          final cached = app.libraryEntryForAsset(asset);
          return Card(
            color: updateMode && selected ? OtaTheme.surfaceHigh : null,
            child: ListTile(
              dense: true,
              title: Text(asset.env, style: const TextStyle(fontSize: 12)),
              subtitle: Text(
                '${asset.version} · ${(asset.size / (1024 * 1024)).toStringAsFixed(2)} MB'
                '${asset.hasSha256 ? ' · sha256 ✓' : ' · no sha256'}',
                style: const TextStyle(color: OtaTheme.textMuted, fontSize: 11),
              ),
              trailing: app.imageLoading && selected
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      cached != null
                          ? Icons.offline_pin
                          : Icons.download_outlined,
                      color: cached != null ? OtaTheme.ok : OtaTheme.textMuted,
                      size: 18,
                    ),
              onTap: app.imageLoading
                  ? null
                  : () => updateMode
                      ? app.selectAsset(asset)
                      : _downloadAsset(context, app, asset),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _downloadAsset(
      BuildContext context, AppState app, FirmwareAsset asset) async {
    final saved = await app.downloadAssetToLibrary(asset);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saved == 1
            ? 'Saved ${asset.name} to the library'
            : (app.libraryEntryForAsset(asset) != null
                ? '${asset.name} is already in the library'
                : 'Could not save ${asset.name}')),
      ),
    );
  }

  static String _date(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
