import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/firmware_library.dart';
import '../services/github_source.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/wizard.dart';
import 'library_screen.dart';
import 'review_screen.dart';

/// Step 4: pick what to install.
///
/// The GitHub listing is scoped to the board the node reported, so an image
/// for a different board cannot be picked by accident, and both release
/// channels are tabs sorted newest-first. Versions are saved for offline use
/// whole (every board), and the Offline tab shows only what this device
/// holds — the app never reaches GitHub while the offline switch is on.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose firmware'),
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
            Tab(text: 'Library'),
          ],
        ),
      ),
      body: Column(
        children: [
          const WizardBar(step: 4, label: 'Choose the image'),
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
                _buildLibraryTab(app),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildSelectionBar(context, app),
    );
  }

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
            detected == null
                ? (board == null
                    ? 'The node did not report a known board — pick one, or '
                        'import a custom .bin in the library.'
                    : 'Scoped to $board. The node did not report a board.')
                : 'Detected from the node: $detected',
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
                        _ReleaseSection(release: release),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildOfflineTab(AppState app) {
    final versions = app.offlineVersions;
    if (versions.isEmpty) {
      return _offlineEmpty(
        icon: Icons.cloud_download_outlined,
        title: 'Nothing saved for offline use yet',
        body: 'On the GitHub tab, save a version with the download button. '
            'Every board\'s image for that version is stored on this device, '
            'so you can update in the field with no signal.',
        action: app.offlineMode
            ? FilledButton.icon(
                onPressed: () => app.setOfflineMode(false),
                icon: const Icon(Icons.cloud_queue),
                label: const Text('Go online'),
              )
            : null,
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${versions.length} version(s) on this device · '
            '${(app.libraryEntries.fold<int>(0, (sum, e) => sum + e.size) / (1024 * 1024)).toStringAsFixed(1)} MB',
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
                    trailing: identical(entry, app.selectedLibraryEntry)
                        ? const Icon(Icons.check, color: OtaTheme.accent)
                        : null,
                    onTap: app.imageLoading
                        ? null
                        : () => app.selectLibraryEntryForUpdate(entry),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLibraryTab(AppState app) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${app.libraryEntries.length} image(s) · '
                  '${(app.libraryEntries.fold<int>(0, (sum, e) => sum + e.size) / (1024 * 1024)).toStringAsFixed(1)} MB',
                  style:
                      const TextStyle(color: OtaTheme.textMuted, fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LibraryScreen()),
                ),
                icon: const Icon(Icons.inventory_2_outlined, size: 18),
                label: const Text('Manage'),
              ),
            ],
          ),
        ),
        Expanded(
          child: app.libraryEntries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Library is empty. Save a version on the GitHub tab (all '
                    'of its images are cached here), or import a .bin file '
                    'from the library screen.',
                    style: TextStyle(
                        color: OtaTheme.textMuted, fontSize: 12, height: 1.5),
                  ),
                )
              : ListView(
                  children: [
                    for (final entry in app.libraryEntries)
                      Card(
                        color: identical(entry, app.selectedLibraryEntry)
                            ? OtaTheme.surfaceHigh
                            : null,
                        child: ListTile(
                          leading:
                              const Icon(Icons.memory, color: OtaTheme.accent),
                          title: Text(entry.fileName,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 12)),
                          subtitle: Text(
                            '${entry.env} · ${entry.version} · ${(entry.size / (1024 * 1024)).toStringAsFixed(2)} MB',
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
                              : null,
                          onTap: app.imageLoading
                              ? null
                              : () => app.selectLibraryEntryForUpdate(entry),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
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
  const _ReleaseSection({required this.release});

  final FirmwareRelease release;

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
          return Card(
            color: selected ? OtaTheme.surfaceHigh : null,
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
                      app.libraryEntryForAsset(asset) != null
                          ? Icons.offline_pin
                          : Icons.download_outlined,
                      color: app.libraryEntryForAsset(asset) != null
                          ? OtaTheme.ok
                          : OtaTheme.textMuted,
                      size: 18,
                    ),
              onTap: app.imageLoading ? null : () => app.selectAsset(asset),
            ),
          );
        }),
      ],
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
