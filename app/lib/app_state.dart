import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:companion_client/companion_client.dart';
import 'package:crypto/crypto.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:ota_core/ota_core.dart';
import 'package:path_provider/path_provider.dart';

import 'services/ble_device_link.dart';
import 'services/firmware_library.dart';
import 'services/github_source.dart';
import 'services/radio_plan.dart';
import 'services/update_flow.dart';

enum ConnectionPhase { disconnected, connecting, connected }

/// Which release channel the firmware picker is showing. Both are sorted
/// newest-first; dev builds are their own tab rather than a switch buried
/// under the stable list.
enum ReleaseTrack { stable, dev }

enum UpdatePhase {
  idle,
  probing,
  staging,
  transferring,
  readyToApply,
  applying,
  verifying,
  done,
  failed,
}

/// Everything the UI binds to. The app has exactly one job — take a
/// repeater to a chosen firmware — so one state object with explicit steps
/// is the right shape. Navigation is a step flow (connect → target →
/// firmware → review → transfer → verify).
class AppState extends ChangeNotifier {
  AppState();

  // ---------------- transport ----------------

  /// 'ble' or 'tcp' — the bench-validation path is TCP to 127.0.0.1.
  String transportKind = 'ble';
  String tcpHost = '127.0.0.1';
  int tcpPort = defaultCompanionPort;

  ConnectionPhase connectionPhase = ConnectionPhase.disconnected;
  String? connectError;
  String companionName = '';

  /// Test seam: overrides the TCP link built by [connectTcp] (the screen
  /// cannot inject one). Null in production, where a real TcpDeviceLink is
  /// built.
  RadioLink Function(String host, int port)? tcpLinkFactory;

  RadioLink? _link;
  CompanionClient? _client;
  UpdateFlow? _flow;

  RadioLink? get link => _link;
  CompanionClient? get client => _client;
  UpdateFlow? get flow => _flow;

  // ---------------- target ----------------

  List<Contact> contacts = const [];
  Contact? target;

  /// Admin password for the current session only — never persisted. May be
  /// empty when the companion's key already holds admin rights on the node
  /// (the repeater's ACL grants admin without a password).
  String adminPassword = '';

  OtaStatus? nodeStatus;

  /// What the node said in the `OP_INFO` handshake: capabilities, target id,
  /// and the running image's full SHA-256 (the delta base identity). Null on
  /// firmware without the handshake.
  OtaNodeInfo? nodeInfo;

  /// The node's primary radio preset, read with `get radio` while checking
  /// it. Used to suggest and validate the off-mesh transfer settings.
  LoRaPreset? nodePreset;

  /// Whether radio2 is enabled on the node, and its status line, read with
  /// `radio2 status`. `null` means the question was not answered.
  bool? radio2Enabled;
  String? radio2Status;

  bool probing = false;
  String? probeError;

  bool get otaSupported => nodeStatus != null;

  // ---------------- firmware selection ----------------

  GitHubSource? _source;
  Catalog? catalog;
  bool catalogLoading = false;
  ReleaseTrack releaseTrack = ReleaseTrack.stable;
  String? catalogError;

  /// When on, the app never reaches GitHub: the picker shows only versions
  /// already saved on this device. Persisted, because the field is exactly
  /// where the setting matters (no signal, app restarted).
  bool offlineMode = false;
  File? _settingsFile;

  /// The release currently being saved for offline use (a second save waits).
  String? downloadingReleaseTag;

  /// The board (build environment) the firmware picker is scoped to. It is
  /// pre-filled from the node's `OP_INFO` target id as soon as the catalog or
  /// library knows that environment's name.

  FirmwareLibrary? library;
  List<LibraryEntry> libraryEntries = const [];

  /// A GitHub asset chosen for install.
  FirmwareAsset? selectedAsset;

  /// A library entry chosen for install (offline mode, or a custom `.bin`).
  LibraryEntry? selectedLibraryEntry;

  /// Board the operator assigned to an image whose file name has none. The
  /// node needs its build id in the OTA start op; this is how we get one when
  /// the handshake did not answer. Never persisted — it belongs to this
  /// selection only.
  String? selectedBoardOverride;

  /// True when an image is selected but neither the file name nor the node
  /// gave us a board, so the operator still has to choose one.
  bool needsBoardForImage = false;

  Uint8List? _selectedImage;
  Uint8List? get selectedImage => _selectedImage;
  bool imageLoading = false;
  String? imageError;

  /// The diff computed by hashing the node's running image (step 5). No local
  /// copy of the old firmware is needed: the node is the oracle for its bytes.
  RemoteDiffResult? remoteDiff;
  RemoteDiffProgress? compareProgress;
  bool comparing = false;
  String? compareError;

  /// The connected node must implement OP_BLOCK_HASH for a remote diff. The
  /// app does not carry a legacy local-delta path.
  bool get blockHashSupported =>
      nodeInfo != null && (nodeInfo!.features & otaFeatBlockHash) != 0;

  /// Drop a comparison that belongs to another node or another image.
  void clearComparison() {
    remoteDiff = null;
    compareProgress = null;
    compareError = null;
    comparing = false;
  }

  // ---------------- radio ----------------

  /// How the transfer reaches the node: the live mesh, a temporary private
  /// preset shared by both ends, or the repeater's second preset.
  RadioPlan radioPlan = const RadioPlan();

  /// The companion's live preset (read when a connection is adopted).
  LoRaPreset? companionPreset;

  /// The preset the companion was on before an off-mesh plan moved it, so it
  /// can be put back afterwards.
  LoRaPreset? _restorePreset;

  /// Whether this update enabled radio2 on the node (and must turn it off
  /// again). False when the node already had radio2 enabled.
  bool _enabledRadio2ForUpdate = false;

  /// Whether the suggested preset/duration may still follow the node/image;
  /// an operator edit pins them.
  bool _radioPresetAuto = true;
  bool _radioDurationAuto = true;

  /// Whether the radio has been moved off the live preset for this transfer.
  bool _radioMoved = false;

  String? radioPlanError;

  // ---------------- update ----------------

  UpdatePhase updatePhase = UpdatePhase.idle;
  TransferProgress? progress;
  final List<String> log = [];
  bool cancelRequested = false;

  /// Whether the node answered with the newly sent image's hash (the only
  /// proof an update worked — see AGENTS.md).
  bool verifyMatched = false;

  /// Whether the last completed action was a rollback. The verify screen must
  /// never present a rollback as a verified update.
  bool rolledBack = false;

  // ---------------- lifecycle ----------------

  Future<FirmwareLibrary> _openLibrary() async {
    final existing = library;
    if (existing != null) return existing;
    final support = await getApplicationSupportDirectory();
    final opened = await FirmwareLibrary.open(support);
    library = opened;
    return opened;
  }

  Future<GitHubSource> _openSource() async {
    final existing = _source;
    if (existing != null) return existing;
    final dir = await getTemporaryDirectory();
    _source = GitHubSource(
      fetchJson: httpFetchJson,
      fetchBytes: httpFetchBytes,
      cacheFile: File('${dir.path}/meshcore_ota_catalog.json'),
    );
    return _source!;
  }

  Future<void> initServices() async {
    try {
      final support = await getApplicationSupportDirectory();
      _settingsFile = File('${support.path}/ota_settings.json');
      if (await _settingsFile!.exists()) {
        final decoded = jsonDecode(await _settingsFile!.readAsString());
        if (decoded is Map && decoded['offline'] == true) offlineMode = true;
      }
    } catch (_) {
      // Settings are a convenience; a read failure must not stop the app.
    }
    final lib = await _openLibrary();
    libraryEntries = await lib.list();
    notifyListeners();
  }

  Future<void> setOfflineMode(bool value) async {
    if (offlineMode == value) return;
    offlineMode = value;
    notifyListeners();
    try {
      final file = _settingsFile;
      if (file != null) {
        await file.writeAsString(jsonEncode({'offline': offlineMode}),
            flush: true);
      }
    } catch (_) {
      // Best effort: the switch still works for this session.
    }
    if (!offlineMode && catalog == null) unawaited(loadCatalog());
  }

  // ---------------- connection ----------------

  Future<void> connectBle(BluetoothDevice device) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
    transportKind = 'ble';
    notifyListeners();
    try {
      final ble = BleDeviceLink(device: device);
      await ble.connect();
      await _adoptLink(ble);
    } catch (e) {
      connectionPhase = ConnectionPhase.disconnected;
      connectError = 'BLE connect failed: $e';
      notifyListeners();
    }
  }

  Future<void> connectTcp({
    required String host,
    required int port,
  }) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
    transportKind = 'tcp';
    tcpHost = host;
    tcpPort = port;
    notifyListeners();
    try {
      final tcp = tcpLinkFactory?.call(host, port) ??
          TcpDeviceLink(host: host, port: port);
      await tcp.connect();
      await _adoptLink(tcp);
    } catch (e) {
      connectionPhase = ConnectionPhase.disconnected;
      connectError = 'TCP connect failed: $e';
      notifyListeners();
    }
  }

  Future<void> _adoptLink(RadioLink link) async {
    _link = link;
    _client = CompanionClient(link, onUnexpectedMessage: (m) {
      log_('unrelated msg from ${bytesToHex(m.senderPrefix)}: ${m.text}');
    });
    _flow = UpdateFlow(client: _client!, link: link, onLog: log_);
    try {
      final info = await link.selfInfo();
      companionName = info.nodeName;
      companionPreset = LoRaPreset(
        frequencyHz: info.radioParams.frequencyHz,
        bandwidthHz: info.radioParams.bandwidthHz,
        spreadingFactor: info.radioParams.spreadingFactor,
        codingRate: info.radioParams.codingRate,
      );
    } catch (_) {
      companionName = '';
    }
    await _refreshContacts();
    connectionPhase = ConnectionPhase.connected;
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _disposeLink();
    notifyListeners();
  }

  Future<void> _disposeLink() async {
    try {
      await _link?.disconnect();
    } catch (_) {}
    _link = null;
    _client = null;
    _flow = null;
    connectionPhase = ConnectionPhase.disconnected;
    contacts = const [];
    target = null;
    nodeStatus = null;
    nodeInfo = null;
    nodePreset = null;
    radio2Enabled = null;
    radio2Status = null;
    companionName = '';
    companionPreset = null;
    manualRoutePath = '';
  }

  Future<void> _refreshContacts() async {
    try {
      contacts = await _client?.listContacts() ?? const [];
    } catch (e) {
      contacts = const [];
      log_('contacts list failed: $e');
    }
    notifyListeners();
  }

  Future<void> refreshContacts() => _refreshContacts();

  // ---------------- target selection ----------------

  /// Optional comma-separated DIRECT path hashes entered on the review screen
  /// (e.g. `c0ff, c0c0`). Empty keeps the saved contact path or zero-hop.
  String manualRoutePath = '';

  String? manualRouteError;

  void setManualRoutePath(String value) {
    manualRoutePath = value;
    manualRouteError = null;
    if (value.trim().isNotEmpty) {
      try {
        OtaRoute.parsePathList(value);
      } catch (e) {
        manualRouteError = '$e';
      }
    }
    notifyListeners();
  }

  /// Add a manual target by hex public key (for nodes not in contacts).
  /// [pubkeyHex] must be 64 hex chars. The pseudo-contact has no saved
  /// path; routing falls back to whatever DIRECT route the companion
  /// decides, which for zero-hop neighbours is direct.
  Contact? addManualTarget(String pubkeyHex, {String name = 'manual target'}) {
    final hex = pubkeyHex.trim().toLowerCase().replaceAll(RegExp(r'\s'), '');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
    final contact = Contact(
        publicKey: hexToBytes(hex), name: name, advType: advTypeRepeater);
    target = contact;
    _resetNodeFacts();
    notifyListeners();
    return contact;
  }

  /// Everything that described the previously checked node. Changing target
  /// must drop it: a diff against another node's running image is worse than
  /// none.
  void _resetNodeFacts() {
    nodeStatus = null;
    nodeInfo = null;
    nodePreset = null;
    radio2Enabled = null;
    radio2Status = null;
    clearComparison();
    _radioPresetAuto = true;
    _radioDurationAuto = true;
    manualRoutePath = '';
    manualRouteError = null;
    probeError = null;
  }

  void selectTarget(Contact contact) {
    target = contact;
    _resetNodeFacts();
    notifyListeners();
  }

  /// Admin login + `ota status` + the capability handshake and radio facts.
  /// Populates [nodeStatus] on success; [probeError] carries the device/app
  /// error on failure.
  ///
  /// [password] may be empty: the repeater treats a blank login as "is this
  /// key already in my ACL?", so a companion whose key is an admin needs no
  /// password at all.
  Future<void> probe({String? password}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) return;
    final secret = password ?? adminPassword;
    probing = true;
    probeError = null;
    notifyListeners();
    try {
      nodeStatus = await flow.probe(t, secret);
      // The handshake is what makes a delta base and the board exact, but a
      // node without it still updates (its `running=` stamp is the fallback).
      nodeInfo = nodeStatus == null ? null : await flow.tryNodeInfo(t);
      if (nodeStatus == null) {
        probeError = 'This firmware does not speak the ota CLI '
            '(expected a fork lora-ota build, e.g. Xiao_S3_WIO_repeater-*-lora-ota).';
      } else {
        // The radio facts are only needed for the off-mesh transfer options;
        // old firmware answers neither, and neither query makes the probe fail.
        final radio = await _cliQuiet(t, 'get radio');
        nodePreset = radio == null ? null : LoRaPreset.parse(radio);
        radio2Status = await _cliQuiet(t, 'radio2 status');
        final radio2 = radio2Status?.trim().toLowerCase();
        radio2Enabled = radio2 == null
            ? null
            : (radio2.startsWith('on')
                ? true
                : radio2.startsWith('off')
                    ? false
                    : null);
        _prefillRadioPlan();
        // A new node needs a fresh comparison against its own running image.
        if (_selectedImage != null) clearComparison();
      }
    } catch (e) {
      nodeStatus = null;
      nodeInfo = null;
      nodePreset = null;
      radio2Enabled = null;
      radio2Status = null;
      probeError = '$e';
    } finally {
      probing = false;
      notifyListeners();
    }
  }

  /// A CLI read on the checked node that is allowed to fail (old firmware,
  /// a command the role does not expose). Returns null on any error.
  Future<String?> _cliQuiet(Contact t, String command) async {
    try {
      return await _flow!.client.remoteCli(t, command);
    } catch (_) {
      return null;
    }
  }

  // ---------------- firmware selection ----------------

  Future<void> loadCatalog({bool forceRefresh = false}) async {
    catalogLoading = true;
    catalogError = null;
    notifyListeners();
    try {
      final source = await _openSource();
      catalog = await source.catalog(
        forceRefresh: forceRefresh && !offlineMode,
        cacheOnly: offlineMode,
      );
    } catch (e) {
      // Offline with no cache is not an error: the GitHub tab shows what
      // this device holds.
      if (!offlineMode) catalog = null;
      catalogError = offlineMode
          ? 'Offline — no cached release list. Downloaded versions are '
              'shown in the GitHub tab.'
          : '$e';
    } finally {
      catalogLoading = false;
      notifyListeners();
    }
  }

  void setReleaseTrack(ReleaseTrack track) {
    releaseTrack = track;
    notifyListeners();
  }

  /// Every build environment the app can name (from the catalog and the
  /// library). Board detection maps the node's target id back into this set.
  Set<String> get knownEnvironments {
    final out = <String>{};
    for (final release in catalog?.releases ?? const <FirmwareRelease>[]) {
      for (final asset in release.appImages) {
        out.add(asset.env);
      }
    }
    for (final entry in libraryEntries) {
      if (entry.env != customEnvironment && entry.env != 'unknown') {
        out.add(entry.env);
      }
    }
    return out;
  }

  /// The environment whose build id is [targetId], if the app knows that
  /// environment's name. The node reports the id only (`sha256(env)[0..3]`),
  /// so this is the inverse lookup the picker needs.
  String? environmentForTargetId(int targetId) {
    final envs = knownEnvironments.toList()..sort();
    for (final env in envs) {
      if (targetIdForEnvironment(env) == targetId) return env;
    }
    return null;
  }

  /// The board the checked node runs, as far as the app can tell. Null when
  /// the node did not answer the handshake or its build is not in the catalog
  /// or library (a custom build).
  String? get detectedBoard {
    final info = nodeInfo;
    if (info == null) return null;
    return environmentForTargetId(info.targetId);
  }

  Future<void> refreshLibrary() async {
    final lib = await _openLibrary();
    libraryEntries = await lib.list();
    notifyListeners();
  }

  /// The releases for the selected track with an image built for [env], newest
  /// first. Null [env] shows everything — used when there is no node to scope
  /// against (the standalone library). A release with no image for the node's
  /// board is hidden rather than shown and refused later.
  List<FirmwareRelease> visibleReleasesFor(String? env) {
    final dev = releaseTrack == ReleaseTrack.dev;
    final out = (catalog?.releases ?? const <FirmwareRelease>[])
        .where((r) => r.isDevTrack == dev)
        .where((r) => env == null || r.appImages.any((a) => a.env == env))
        .toList()
      ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    return out;
  }

  /// The image of [release] built for [env], or null when it has none.
  FirmwareAsset? assetForEnvironment(FirmwareRelease release, String? env) {
    if (env == null) return null;
    for (final asset in release.appImages) {
      if (asset.env == env) return asset;
    }
    return null;
  }

  /// Select a GitHub asset and load (download) its bytes.
  Future<void> selectAsset(FirmwareAsset asset) async {
    selectedAsset = asset;
    selectedLibraryEntry = null;
    selectedBoardOverride = null;
    needsBoardForImage = false;
    _selectedImage = null;
    clearComparison();
    imageLoading = true;
    imageError = null;
    notifyListeners();
    try {
      // A version saved for offline use is already on disk; selecting it must
      // never reach GitHub (the field has no signal).
      final cached = libraryEntryForAsset(asset);
      if (cached != null) {
        final lib = await _openLibrary();
        _selectedImage = await lib.read(cached);
        selectedLibraryEntry = cached;
        await _refreshRadioDuration();
        return;
      }
      if (offlineMode) {
        throw StateError(
            'offline — save this version for offline use before selecting it');
      }
      final bytes = await (await _openSource()).downloadAsset(asset);
      _selectedImage = bytes;
      final entry = await _importImage(
        bytes,
        env: asset.env,
        version: asset.version,
        origin: 'github',
        fileName: asset.name,
      );
      selectedLibraryEntry = entry;
      await _refreshRadioDuration();
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      notifyListeners();
    }
  }

  /// The library image for [asset], matched by its file name or (when the
  /// release publishes sums) its SHA-256.
  LibraryEntry? libraryEntryForAsset(FirmwareAsset asset) {
    for (final entry in libraryEntries) {
      if (entry.fileName == asset.name) return entry;
      if (asset.sha256 != null && entry.sha256 == asset.sha256) return entry;
    }
    return null;
  }

  /// Save every image of [release] for offline use — all boards, so the
  /// device carries a complete version rather than a per-device guess.
  /// Returns how many images were newly saved.
  Future<int> downloadReleaseToLibrary(FirmwareRelease release) async {
    if (offlineMode) {
      log_('offline mode — go online to download a version');
      return 0;
    }
    if (downloadingReleaseTag != null) return 0;
    final total = release.appImages.length;
    if (total == 0) return 0;
    final missing = release.appImages
        .where((a) => libraryEntryForAsset(a) == null)
        .toList();
    if (missing.isEmpty) {
      log_('${release.tag} was already saved for offline use');
      return 0;
    }
    downloadingReleaseTag = release.tag;
    notifyListeners();
    var saved = 0;
    try {
      final source = await _openSource();
      for (final asset in missing) {
        final bytes = await source.downloadAsset(asset);
        await _importImage(
          bytes,
          env: asset.env,
          version: asset.version,
          origin: 'github',
          fileName: asset.name,
        );
        saved++;
        notifyListeners();
      }
      log_(saved == 0
          ? '${release.tag} was already saved for offline use'
          : 'saved ${release.tag} for offline use ($saved image(s))');
    } catch (e) {
      log_('saving ${release.tag} failed after $saved image(s): $e');
    } finally {
      downloadingReleaseTag = null;
      notifyListeners();
    }
    return saved;
  }

  /// Downloaded GitHub versions, newest first: the offline view. Imported
  /// `.bin` files are deliberately not grouped here — they are their own
  /// list ([importedEntries]); only images fetched from releases appear.
  /// A version is "complete" when the catalog says every asset of that
  /// release is here.
  List<OfflineVersion> get offlineVersions {
    final byVersion = <String, List<LibraryEntry>>{};
    for (final entry in libraryEntries) {
      if (entry.origin != 'github') continue;
      byVersion.putIfAbsent(entry.version, () => []).add(entry);
    }
    final releasesByVersion = <String, FirmwareRelease>{};
    for (final release in catalog?.releases ?? const <FirmwareRelease>[]) {
      for (final asset in release.appImages) {
        releasesByVersion.putIfAbsent(asset.version, () => release);
      }
    }
    final out = <OfflineVersion>[];
    for (final group in byVersion.entries) {
      final release = releasesByVersion[group.key];
      final entries = group.value..sort((a, b) => a.env.compareTo(b.env));
      final complete = release != null &&
          release.appImages.every((a) => libraryEntryForAsset(a) != null);
      out.add(OfflineVersion(
        version: group.key,
        tag: release?.tag,
        entries: entries,
        complete: complete,
        known: release != null,
        isDev: release?.isDevTrack ?? group.key.contains('-dev.'),
        totalAssets: release?.appImages.length ?? entries.length,
      ));
    }
    out.sort((a, b) => b.entries.first.added.compareTo(a.entries.first.added));
    return out;
  }

  /// Imported `.bin` files, newest first — the custom/local half of the
  /// library. Identity is the SHA-256, so an imported image is a delta base
  /// or an update candidate exactly like a downloaded one.
  List<LibraryEntry> get importedEntries =>
      libraryEntries.where((e) => e.origin != 'github').toList()
        ..sort((a, b) => b.added.compareTo(a.added));

  /// Save just [asset] to the library (the standalone library manager's
  /// download). Returns 1 when newly saved, 0 when already present,
  /// refused (offline) or failed.
  Future<int> downloadAssetToLibrary(FirmwareAsset asset) async {
    if (offlineMode) return 0;
    if (downloadingReleaseTag != null) return 0;
    if (libraryEntryForAsset(asset) != null) return 0;
    try {
      final source = await _openSource();
      final bytes = await source.downloadAsset(asset);
      await _importImage(
        bytes,
        env: asset.env,
        version: asset.version,
        origin: 'github',
        fileName: asset.name,
      );
      return 1;
    } catch (e) {
      log_('saving ${asset.name} failed: $e');
      return 0;
    }
  }

  /// Delete [entries] from the library and repair any selection that pointed
  /// at them: the image, the explicit delta base and the forced-full-image
  /// choice are all dropped rather than left dangling.
  Future<void> deleteLibraryEntries(Iterable<LibraryEntry> entries) async {
    final list = entries.toList();
    if (list.isEmpty) return;
    final removed = list.map((e) => e.id).toSet();
    final lib = await _openLibrary();
    for (final entry in list) {
      await lib.delete(entry);
    }
    if (selectedLibraryEntry != null &&
        removed.contains(selectedLibraryEntry!.id)) {
      selectedLibraryEntry = null;
      selectedAsset = null;
      selectedBoardOverride = null;
      needsBoardForImage = false;
      _selectedImage = null;
      clearComparison();
      imageError = null;
    }
    await refreshLibrary();
    await _refreshRadioDuration();
    notifyListeners();
  }

  Future<LibraryEntry> _importImage(
    Uint8List bytes, {
    required String env,
    required String version,
    required String origin,
    String? fileName,
  }) async {
    final lib = await _openLibrary();
    final entry = await lib.importBytes(
      bytes,
      env: env,
      version: version,
      origin: origin,
      fileName: fileName,
    );
    libraryEntries = await lib.list();
    notifyListeners();
    return entry;
  }

  /// Import a `.bin` as a library entry. Used for custom builds and for the
  /// "the file this node already has" base: the name is only metadata, the
  /// SHA-256 is the identity.
  Future<LibraryEntry> importLocalImage(
    Uint8List bytes, {
    required String fileName,
    String? env,
    String? version,
  }) =>
      _importImage(
        bytes,
        env: env ?? customEnvironment,
        version: version ?? _versionFromFileName(fileName),
        origin: 'import',
        fileName: fileName,
      );

  /// Select a library entry for install (offline mode, or a custom `.bin`).
  Future<void> selectLibraryEntryForUpdate(LibraryEntry entry) async {
    selectedLibraryEntry = entry;
    selectedAsset = null;
    selectedBoardOverride = null;
    needsBoardForImage = false;
    _selectedImage = null;
    clearComparison();
    imageLoading = true;
    imageError = null;
    notifyListeners();
    try {
      final lib = await _openLibrary();
      _selectedImage = await lib.read(entry);
      // A renamed `.bin` has no board in its name. The node's own handshake is
      // the only authority; retry it with a longer timeout, then ask the
      // operator rather than guessing from a file name or a hash.
      if (nodeInfo == null &&
          (entry.env == customEnvironment || entry.env == 'unknown')) {
        if (!await retryNodeInfo()) needsBoardForImage = true;
        notifyListeners();
      }
      await _refreshRadioDuration();
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      notifyListeners();
    }
  }

  /// Step 5's work: ask the node to hash ranges of its running image and
  /// derive the op stream from the answers. Read-only — nothing is staged and
  /// the radio is untouched until the operator starts the update.
  Future<void> planComparison() async {
    final t = target;
    final link = _link;
    final image = _selectedImage;
    if (t == null || link == null || image == null) return;
    if (!blockHashSupported) {
      compareError = 'This repeater does not support comparing its running '
          'image. Update its firmware over USB first.';
      notifyListeners();
      return;
    }
    comparing = true;
    compareError = null;
    compareProgress = null;
    remoteDiff = null;
    notifyListeners();
    final client = BlockHashClient(
        link: link, contact: t, timeout: const Duration(seconds: 10));
    try {
      remoteDiff = await computeRemoteDiff(
        client: client,
        image: image,
        onProgress: (p) {
          compareProgress = p;
          notifyListeners();
        },
        shouldCancel: () => cancelRequested,
      );
      await _refreshRadioDuration();
    } catch (e) {
      compareError = '$e';
      remoteDiff = null;
    } finally {
      comparing = false;
      notifyListeners();
    }
  }

  /// Re-run step 5 (e.g. after a failed comparison or a changed image).
  Future<void> retryComparison() async {
    cancelRequested = false;
    await planComparison();
  }

  /// Environment of the current selection (asset env or library env, with a
  /// board chosen by the operator as the fallback for a custom `.bin`).
  String? get selectedEnvironment {
    final asset = selectedAsset;
    if (asset != null) return asset.env;
    final entry = selectedLibraryEntry;
    if (entry == null) return null;
    return selectedBoardOverride ?? entry.env;
  }

  /// Give the handshake another, longer chance before asking the operator to
  /// name the board. Sign-in's 2 s probe is often too short over a mesh, and
  /// the node's own target id is better than any guess from a file name.
  Future<bool> retryNodeInfo() async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) return false;
    final info = await flow.tryNodeInfo(t, timeout: const Duration(seconds: 8));
    if (info == null) return false;
    nodeInfo = info;
    notifyListeners();
    return true;
  }

  /// Use [env] as the board of the selected image for this session.
  Future<void> setSelectedBoard(String env) async {
    selectedBoardOverride = env;
    needsBoardForImage = false;
    notifyListeners();
    await _refreshRadioDuration();
  }

  /// Version of the current selection, full stamp.
  String? get selectedVersion =>
      selectedAsset?.version ?? selectedLibraryEntry?.version;

  /// Display version of the current selection.
  String? get selectedDisplayVersion =>
      selectedAsset?.displayVersion ?? selectedLibraryEntry?.version;

  /// The preset the node's live mesh runs on (falls back to the companion's —
  /// the same mesh when the update path works at all).
  LoRaPreset? get livePreset => nodePreset ?? companionPreset;

  // ---------------- radio plan ----------------

  void setRadioMode(RadioMode mode) {
    if (radioPlan.mode == mode) return;
    radioPlan = radioPlan.copyWith(mode: mode);
    radioPlanError = null;
    if (radioPlan.usesRadio && radioPlan.preset == null) {
      _radioPresetAuto = true;
      _radioDurationAuto = true;
      _prefillRadioPreset();
      _refreshRadioDuration();
    }
    notifyListeners();
  }

  void setRadioPreset(LoRaPreset preset) {
    radioPlan = radioPlan.copyWith(preset: preset);
    _radioPresetAuto = false;
    radioPlanError = null;
    notifyListeners();
  }

  void setRadioDuration(int minutes) {
    radioPlan = radioPlan.copyWith(
        durationMinutes: minutes.clamp(
            RadioPlan.minDurationMinutes, RadioPlan.maxDurationMinutes));
    _radioDurationAuto = false;
    radioPlanError = null;
    notifyListeners();
  }

  /// The reason the plan cannot start, or null. Recomputed on demand so the
  /// UI always reflects the live preset.
  String? get radioPlanProblem => radioPlan.error(primary: livePreset);

  /// A suggested preset for the current mode, or null for live-mesh mode.
  LoRaPreset? suggestedRadioPreset() {
    final live = livePreset;
    if (live == null || radioPlan.mode == RadioMode.liveMesh) return null;
    return radioPlan.mode == RadioMode.radio2
        ? RadioPlan.suggestRadio2(live)
        : RadioPlan.suggestTempRadio(live);
  }

  /// A transfer-duration suggestion in minutes, from the airtime estimate.
  Future<int> suggestedRadioDurationMinutes() async =>
      RadioPlan.suggestDurationMinutes(await estimateTransferSeconds());

  void _prefillRadioPreset() {
    final live = livePreset;
    if (live == null) return;
    radioPlan = radioPlan.copyWith(
        preset: radioPlan.mode == RadioMode.radio2
            ? RadioPlan.suggestRadio2(live)
            : RadioPlan.suggestTempRadio(live));
  }

  Future<void> _refreshRadioDuration() async {
    if (!_radioDurationAuto) return;
    final minutes = await suggestedRadioDurationMinutes();
    if (!_radioDurationAuto) return; // the operator typed meanwhile
    radioPlan = radioPlan.copyWith(durationMinutes: minutes);
    notifyListeners();
  }

  /// Called after a successful probe: the node's preset is what the plan
  /// must clear.
  void _prefillRadioPlan() {
    if (!radioPlan.usesRadio) return;
    if (_radioPresetAuto || radioPlan.preset == null) _prefillRadioPreset();
    _refreshRadioDuration();
  }

  /// The whole-image hash from step 5, not a library match, decides equality.
  bool get selectedImageIsRunning => remoteDiff?.upToDate ?? false;

  /// Estimated transfer size: literal bytes from the remote diff, or the full
  /// image before step 5 has run.
  int? get estimatedTransferBytes =>
      remoteDiff?.literalBytes ?? _selectedImage?.length;

  /// A compact label for the chosen image's transfer size.
  String estimateLabel() {
    final bytes = estimatedTransferBytes;
    if (bytes == null) return 'size unknown';
    final text = bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
        : '${(bytes / 1024).toStringAsFixed(0)} KB';
    return remoteDiff != null ? 'remote diff ~$text' : 'full $text';
  }

  /// Wall time per op on a stock companion, in seconds.
  ///
  /// The node is deaf while each literal op is committed to flash, so the rate
  /// limiter is the node's flash write latency, not airtime — an airtime model
  /// is ~15x optimistic on real hardware (measured ~1.4–1.5 s per literal op:
  /// a 426 KB delta took ~1 hour on an expected ~4 minutes). Synchronous so a
  /// settings screen can compare modes while the user types.
  static const double estimateOpSeconds = 1.5;

  /// Transfer estimate in seconds for the selected image. [factor] scales for
  /// radio2 (it shares the radio, so ops cost roughly twice as long).
  int? estimateSecondsForPreset(LoRaPreset? preset, {double factor = 1.0}) {
    final bytes = estimatedTransferBytes;
    if (preset == null || bytes == null || bytes <= 0) return null;
    // The literal size the transfer actually sends — the stock companion's
    // frame limit, not the on-air maximum (see wireOpsFor).
    final ops = (bytes / otaLiteralChunkForBinaryReq()).ceil() + 16;
    return (ops * estimateOpSeconds * factor).ceil();
  }

  /// Transfer estimate in seconds for [mode] at the current selection. The
  /// preset is the plan's (for off-mesh modes) or the live one.
  int? estimateSecondsForMode(RadioMode mode, {LoRaPreset? preset}) {
    final chosen = mode == RadioMode.liveMesh
        ? livePreset
        : (preset ?? radioPlan.preset ?? livePreset);
    final factor = mode == RadioMode.radio2 ? RadioPlan.radio2DutyFactor : 1.0;
    return estimateSecondsForPreset(chosen, factor: factor);
  }

  /// Transfer estimate in seconds at the preset the transfer will use, or
  /// null when the radio parameters are unavailable.
  Future<int?> estimateTransferSeconds() async {
    final image = _selectedImage;
    final link = _link;
    if (image == null || link == null) return null;
    try {
      final preset = radioPlan.usesRadio && radioPlan.preset != null
          ? radioPlan.preset
          : await _liveParams(link);
      return estimateSecondsForPreset(preset, factor: radioPlan.estimateFactor);
    } catch (_) {
      return null;
    }
  }

  Future<LoRaPreset> _liveParams(RadioLink link) async {
    final params = await link.radioParams();
    return LoRaPreset(
      frequencyHz: params.frequencyHz,
      bandwidthHz: params.bandwidthHz,
      spreadingFactor: params.spreadingFactor,
      codingRate: params.codingRate,
    );
  }

  // ---------------- update execution ----------------

  void requestCancel() {
    cancelRequested = true;
    notifyListeners();
  }

  /// Full pipeline: move the radio if asked, stage → transfer → report ready,
  /// then put the radio back. Throws on any failure and leaves [updatePhase]
  /// at `failed` (or `idle` after a cancel) so the screen can show the way
  /// back; the transfer screen maps the exception to UI.
  Future<void> runUpdate({required String version}) async {
    final t = target;
    final flow = _flow;
    final image = _selectedImage;
    if (t == null || flow == null || image == null) {
      throw StateError('update not ready');
    }
    final planProblem = radioPlanProblem;
    if (planProblem != null) {
      throw UpdateFlowException('radio settings: $planProblem');
    }
    final diff = remoteDiff;
    if (diff == null) {
      throw UpdateFlowException('compare the firmware with the node first');
    }
    if (diff.upToDate) {
      throw UpdateFlowException('this node already runs that image');
    }
    // The node's own target id is the authority when the handshake answered;
    // a custom build has no catalog environment to derive one from.
    final env = selectedEnvironment;
    final expected = (env != null && env != customEnvironment)
        ? targetIdForEnvironment(env)
        : nodeInfo?.targetId;
    final targetId = nodeInfo?.targetId ?? expected;
    if (targetId == null) {
      throw UpdateFlowException('choose the firmware board before starting');
    }
    // Resolve the route before arming so a bad manual path leaves no armed
    // staging session behind. Off-mesh modes are zero-hop by definition.
    final route = radioPlan.requiresZeroHop ? OtaRoute.zeroHop() : _routeFor(t);
    updatePhase = UpdatePhase.staging;
    log_('arming: ${image.length} bytes, version $version');
    notifyListeners();

    _radioMoved = false;
    try {
      if (radioPlan.requiresZeroHop) {
        await _applyRadioPlan(t);
      }
      final stage = await flow.stage(t, image,
          version: version, expectedTargetId: expected);
      log_(
          'armed: size=${stage.size} token=${stage.token.toRadixString(16).padLeft(8, '0')}');

      // The op stream comes from step 5's hash comparison against this node's
      // running image. Nothing from a local library can be stale here.
      final ops = diff.ops;
      log_('remote diff: ${diff.copyBytes} bytes reused, '
          '${diff.literalBytes} to send (${diff.queries} queries)');

      final sha = sha256List(image);
      updatePhase = UpdatePhase.transferring;
      cancelRequested = false;
      progress = null;
      notifyListeners();

      try {
        await flow.transfer(
          target: t,
          contract: OtaStartContract(
            imageSize: image.length,
            imageSha256: sha,
            targetId: targetId,
            token: stage.token,
          ),
          ops: ops,
          route: route,
          windowSize: 8,
          onProgress: (p) {
            progress = p;
            notifyListeners();
          },
          shouldCancel: () => cancelRequested,
        );
      } on OtaTransferException catch (e) {
        if (cancelRequested) {
          await flow.abortQuietly(t);
          updatePhase = UpdatePhase.idle;
          log_('cancelled — staged image discarded');
          throw UpdateFlowException('cancelled');
        }
        await flow.abortQuietly(t);
        updatePhase = UpdatePhase.failed;
        throw UpdateFlowException('transfer failed: ${e.message}');
      }
      // A transport-layer failure (e.g. the companion's binary-request
      // timeout) throws something that is not an OtaTransferException; it must
      // still end the staged session and leave the UI in the failed state,
      // never stuck with a dead cancel button.
      catch (e) {
        await flow.abortQuietly(t);
        updatePhase = UpdatePhase.failed;
        log_('transfer failed: $e');
        throw UpdateFlowException('transfer failed: $e');
      }

      // Confirm the staged image passed the node's SHA gate.
      await flow.awaitReady(t);
      updatePhase = UpdatePhase.readyToApply;
      log_('staged and verified — ready to apply');
      notifyListeners();
    } catch (e) {
      // Stage/arm/verification failures land here. The transfer path already
      // sets failed (or idle on cancel) before rethrowing — keep those — but
      // anything earlier would otherwise leave the phase stuck at staging or
      // transferring with no way forward.
      if (updatePhase != UpdatePhase.failed &&
          updatePhase != UpdatePhase.idle) {
        updatePhase = UpdatePhase.failed;
        notifyListeners();
      }
      rethrow;
    } finally {
      // Put the radios back before the operator commits: the apply (and its
      // verification) belongs on the live mesh, and the temporary preset was
      // only ever for the transfer.
      if (_radioMoved) await _restoreRadioPlan(t);
    }
  }

  /// Move the repeater and/or the companion onto the transfer preset. Both
  /// firmware CLIs defer the retune for ~2 s so their reply leaves first.
  Future<void> _applyRadioPlan(Contact t) async {
    final link = _link;
    final flow = _flow;
    final preset = radioPlan.preset;
    if (link == null || flow == null || preset == null) {
      throw UpdateFlowException('no link for the radio settings');
    }
    _radioMoved = false;
    _restorePreset = companionPreset ?? await _liveParams(link);
    if (radioPlan.mode == RadioMode.radio2) {
      if (radio2Enabled == true) {
        // Leave the node's own radio2 configuration alone; the operator
        // entered the preset it already uses.
        log_('radio2 already enabled — leaving the node configuration as is');
      } else {
        await _nodeCommand(t, radioPlan.radio2Command);
        _radioMoved = true;
        _enabledRadio2ForUpdate = true;
        log_('radio2 enabled on the node: ${preset.label}');
      }
    } else {
      await _nodeCommand(t, radioPlan.tempRadioCommand);
      _radioMoved = true;
      log_(
          'node moved to ${preset.label} for ${radioPlan.durationMinutes} min');
    }
    final reply = await link.runCliCommand(radioPlan.tempRadioCommand);
    _radioMoved = true;
    if (!reply.trim().toLowerCase().startsWith('ok')) {
      throw UpdateFlowException('the companion refused the temporary preset',
          deviceReply: reply);
    }
    log_(
        'companion moved to ${preset.label} for ${radioPlan.durationMinutes} min');
    // Both ends retune 2 s after queueing the reply.
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  /// Undo [_applyRadioPlan]. Best effort: the transfer already succeeded or
  /// failed, and a radio that stays off-mesh for a few minutes reverts by
  /// itself (the temporary presets are time-boxed on both ends).
  Future<void> _restoreRadioPlan(Contact t) async {
    final link = _link;
    final live = _restorePreset ?? companionPreset;
    try {
      if (_enabledRadio2ForUpdate) {
        // The node must leave radio2 before the companion leaves the shared
        // preset, so the reply has a chance to get out.
        final reply = await _nodeCommandOrNull(t, 'radio2 off');
        _enabledRadio2ForUpdate = false;
        final acknowledged =
            reply != null && reply.trim().toLowerCase().startsWith('ok');
        // Only believe radio2 is off when the node said so; a lost reply leaves
        // the question open rather than recording a false "off".
        radio2Enabled = acknowledged ? false : null;
        log_(acknowledged
            ? 'radio2 turned back off'
            : 'radio2 restore not acknowledged — check the node');
      } else if (radioPlan.mode == RadioMode.tempRadio && live != null) {
        // Send the original preset back, short-lived, so the mesh recovers
        // now instead of when the timer expires. The reply may be lost.
        await _nodeCommandOrNull(t, 'tempradio ${live.cli},1');
      }
    } finally {
      if (link != null && live != null) {
        try {
          final reply = await link.runCliCommand('tempradio ${live.cli},1');
          log_(reply.trim().toLowerCase().startsWith('ok')
              ? 'companion back on ${live.label}'
              : 'companion radio restore said: ${reply.trim()}');
        } catch (e) {
          log_('companion radio restore failed: $e');
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
    _radioMoved = false;
    notifyListeners();
  }

  Future<void> _nodeCommand(Contact t, String command) async {
    final reply = await _flow!.client.remoteCli(t, command);
    if (reply.trim().toLowerCase().startsWith('err') ||
        reply.toLowerCase().contains('error')) {
      throw UpdateFlowException('the node refused "$command"',
          deviceReply: reply);
    }
  }

  Future<String?> _nodeCommandOrNull(Contact t, String command) async {
    try {
      return await _flow!.client
          .remoteCli(t, command, timeout: const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// Commit: `ota apply` → node reboots into the new image.
  Future<void> applyAndVerify({required String expectedVersion}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('no target');
    updatePhase = UpdatePhase.applying;
    notifyListeners();
    try {
      await flow.apply(t);
    } catch (e) {
      updatePhase = UpdatePhase.failed;
      notifyListeners();
      rethrow;
    }
    log_('applied — node is rebooting');
    updatePhase = UpdatePhase.verifying;
    verifyMatched = false;
    rolledBack = false;
    notifyListeners();
    final ok = await flow.awaitVersion(t, adminPassword, expectedVersion,
        expectedImageSha256:
            selectedImage == null ? null : sha256List(selectedImage!));
    verifyMatched = ok;
    updatePhase = ok ? UpdatePhase.done : UpdatePhase.failed;
    notifyListeners();
  }

  /// Roll back the freshly applied update. We cannot know the previous
  /// version string on this node, so [verifyMatched] after a rollback means
  /// only that the node answered admin CLI again — [rolledBack] is what the UI
  /// reports, never "the sent image is running".
  Future<void> rollback() async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('no target');
    updatePhase = UpdatePhase.applying;
    notifyListeners();
    await flow.rollback(t);
    updatePhase = UpdatePhase.verifying;
    notifyListeners();
    final ok = await flow.awaitVersion(t, adminPassword, '');
    verifyMatched = ok;
    rolledBack = ok;
    updatePhase = ok ? UpdatePhase.done : UpdatePhase.failed;
    notifyListeners();
  }

  void log_(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    log.add('[$ts] $message');
    if (log.length > 300) log.removeRange(0, log.length - 300);
    notifyListeners();
  }

  OtaRoute _routeFor(Contact t) {
    final entered = manualRoutePath.trim();
    if (entered.isNotEmpty) {
      try {
        manualRouteError = null;
        return OtaRoute.parsePathList(entered);
      } catch (e) {
        manualRouteError = '$e';
        rethrow;
      }
    }
    if (t.hasDirectRoute) {
      return OtaRoute.fromContactPath(
        outPathLen: t.outPathLen,
        outPath: t.outPath,
      );
    }
    // No known route: zero-hop DIRECT (works for a node on the same radio;
    // the firmware drops everything not routable). The review screen warns.
    return OtaRoute.zeroHop();
  }

  /// A version-ish label for a hand-picked `.bin`: its file name without the
  /// directory and extension.
  static String _versionFromFileName(String fileName) {
    var name = fileName.split(RegExp(r'[/\\]')).last;
    if (name.toLowerCase().endsWith('.bin')) {
      name = name.substring(0, name.length - 4);
    }
    return name.isEmpty ? 'custom' : name;
  }

  static Uint8List sha256List(List<int> data) =>
      Uint8List.fromList(sha256.convert(data).bytes);
}

/// A firmware version this device has images for — the offline view's unit.
///
/// Versions are downloaded whole (every board's image), so the operator picks
/// a version, not a device. Imported `.bin` files are not versions — they
/// have no release to be complete against — so only GitHub downloads appear
/// here. [complete] is meaningful when the catalog still knows the release
/// ([known]).
class OfflineVersion {
  const OfflineVersion({
    required this.version,
    this.tag,
    required this.entries,
    required this.complete,
    required this.known,
    required this.isDev,
    required this.totalAssets,
  });

  final String version;

  /// The release tag (e.g. `filter-v1.1.0-rc5`) when the catalog knows it;
  /// versions are the unit the user thinks in. Null without a catalog.
  final String? tag;
  final List<LibraryEntry> entries;
  final bool complete;
  final bool known;
  final bool isDev;

  /// How many images the whole version has; equal to [entries.length] when
  /// the catalog is unavailable.
  final int totalAssets;
}
