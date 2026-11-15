import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/github_source.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'library_screen.dart';
import 'review_screen.dart';

/// Step 3: pick what to install — the fork's GitHub releases, or the
/// offline library. Downloads land in the library automatically.
class FirmwareScreen extends StatefulWidget {
  const FirmwareScreen({super.key});

  @override
  State<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends State<FirmwareScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _filterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = context.read<AppState>();
      if (app.catalog == null && !app.catalogLoading) {
        app.loadCatalog();
      }
      app.refreshLibrary();
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose firmware'),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: OtaTheme.accent,
          tabs: const [Tab(text: 'GitHub'), Tab(text: 'Library')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildGitHubTab(app), _buildLibraryTab(app)],
      ),
      bottomNavigationBar: _buildSelectionBar(context, app),
    );
  }

  Widget _buildGitHubTab(AppState app) {
    final releases = app.visibleReleases;
    final filter = _filterController.text.trim().toLowerCase();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _filterController,
                  decoration: const InputDecoration(
                    labelText: 'Filter board (e.g. Xiao_S3)',
                    isDense: true,
                    prefixIcon: Icon(Icons.filter_alt_outlined),
                  ),
                  onChanged: (_) => setState(() {}),
                  autocorrect: false,
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
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SwitchListTile(
            value: app.showDevReleases,
            onChanged: app.toggleDevReleases,
            title:
                const Text('Show dev builds', style: TextStyle(fontSize: 13)),
            subtitle: const Text('Filter Firmware dev.N releases',
                style: TextStyle(fontSize: 11)),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        ),
        if (app.catalogFromCache)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Offline — showing cached catalog (may be stale).',
              style: TextStyle(color: OtaTheme.warn, fontSize: 11),
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
                ? const Center(
                    child: Text('No releases found.',
                        style: TextStyle(color: OtaTheme.textMuted)),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      for (final release in releases)
                        _ReleaseSection(release: release, filter: filter),
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
        const SizedBox(height: 4),
        Expanded(
          child: app.libraryEntries.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Library is empty. Pick a release on the GitHub tab — it\'s '
                    'cached here automatically — or import a .bin file.',
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

  Widget? _buildSelectionBar(BuildContext context, AppState app) {
    final ready = app.selectedImage != null &&
        !app.imageLoading &&
        app.imageError == null &&
        app.selectedEnvironment != null;
    final loading = app.imageLoading;
    return Material(
      color: OtaTheme.surface,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (app.imageError != null)
              Text(
                app.imageError!,
                style: const TextStyle(color: OtaTheme.bad, fontSize: 12),
              ),
            FilledButton.icon(
              onPressed: ready
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ReviewScreen()),
                      )
                  : null,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF1A1203),
                      ),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(loading ? 'Downloading…' : 'Review update'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseSection extends StatelessWidget {
  const _ReleaseSection({required this.release, required this.filter});

  final FirmwareRelease release;
  final String filter;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final images = release.appImages.where((a) {
      if (filter.isEmpty) return true;
      return a.env.toLowerCase().contains(filter) ||
          a.version.toLowerCase().contains(filter);
    }).toList()
      ..sort((a, b) => a.env.compareTo(b.env));
    if (images.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  release.tag,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
              StatusPill(
                release.isDevTrack ? 'DEV' : 'STABLE',
                color: release.isDevTrack ? OtaTheme.warn : OtaTheme.ok,
              ),
            ],
          ),
        ),
        ...images.map((asset) {
          final selected = identical(asset, app.selectedAsset);
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
                  : const Icon(Icons.download,
                      color: OtaTheme.textMuted, size: 18),
              onTap: app.imageLoading ? null : () => app.selectAsset(asset),
            ),
          );
        }),
      ],
    );
  }
}
