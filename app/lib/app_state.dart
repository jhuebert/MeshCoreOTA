import 'dart:async';
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
import 'services/update_flow.dart';

enum ConnectionPhase { disconnected, connecting, connected }

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
  RadioLink? _link;
  CompanionClient? _client;
  UpdateFlow? _flow;

  RadioLink? get link => _link;
  CompanionClient? get client => _client;
  UpdateFlow? get flow => _flow;

  // ---------------- target ----------------

  List<Contact> contacts = const [];
  Contact? target;

  /// Admin password for the current session only — never persisted.
  String adminPassword = '';

  OtaStatus? nodeStatus;

  /// What the node said in the `OP_INFO` handshake: capabilities, target id,
  /// and the running image's full SHA-256 (the delta base identity). Null on
  /// firmware without the handshake.
  OtaNodeInfo? nodeInfo;

  bool probing = false;
  String? probeError;

  bool get otaSupported => nodeStatus != null;

  // ---------------- firmware selection ----------------

  GitHubSource? _source;
  Catalog? catalog;
  bool catalogLoading = false;
  bool catalogFromCache = false;
  bool showDevReleases = false;
  String? catalogError;

  FirmwareLibrary? library;
  List<LibraryEntry> libraryEntries = const [];
  bool libraryLoading = false;

  /// A GitHub asset chosen for install.
  FirmwareAsset? selectedAsset;

  /// A library entry chosen for install (offline mode).
  LibraryEntry? selectedLibraryEntry;

  Uint8List? _selectedImage;
  Uint8List? get selectedImage => _selectedImage;
  bool imageLoading = false;
  String? imageError;

  /// The matched delta base (library entry running the node's exact
  /// `running=` stamp). Null → full image.
  LibraryEntry? baseEntry;
  DeltaResult? deltaResult;

  // download bookkeeping
  double? downloadProgress; // 0..1 when known, else null (indeterminate)

  // ---------------- update ----------------

  UpdatePhase updatePhase = UpdatePhase.idle;
  TransferProgress? progress;
  final List<String> log = [];
  bool cancelRequested = false;
  String? updateError;
  bool verifyStateKnown = false;
  bool verifyMatched = false;

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
    final lib = await _openLibrary();
    libraryEntries = await lib.list();
    notifyListeners();
  }

  // ---------------- connection ----------------

  Future<void> connectBle(BluetoothDevice device) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
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

  Future<void> connectTcp({required String host, required int port}) async {
    await _disposeLink();
    connectionPhase = ConnectionPhase.connecting;
    connectError = null;
    notifyListeners();
    try {
      final link = TcpDeviceLink(host: host, port: port);
      await link.connect();
      await _adoptLink(link);
    } catch (e) {
      connectionPhase = ConnectionPhase.disconnected;
      connectError = 'TCP connect failed: $e';
      notifyListeners();
    }
  }

  Future<void> _adoptLink(RadioLink link) async {
    _link = link;
    _client = CompanionClient(link, onUnexpectedMessage: (m) {
      log_('unrelated msg from ${_hex(m.senderPrefix)}: ${m.text}');
    });
    _flow = UpdateFlow(client: _client!, link: link);
    try {
      final info = await link.selfInfo();
      companionName = info.nodeName;
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
    companionName = '';
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
    final bytes = Uint8List.fromList(List<int>.generate(
        32, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
    final contact =
        Contact(publicKey: bytes, name: name, advType: advTypeRepeater);
    target = contact;
    nodeStatus = null;
    nodeInfo = null;
    manualRoutePath = '';
    manualRouteError = null;
    notifyListeners();
    return contact;
  }

  void selectTarget(Contact contact) {
    target = contact;
    nodeStatus = null;
    nodeInfo = null;
    probeError = null;
    manualRoutePath = '';
    manualRouteError = null;
    notifyListeners();
  }

  /// Admin login + `ota status`. Populates [nodeStatus] on success;
  /// [probeError] carries the device/app error on failure.
  Future<void> probe() async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) return;
    probing = true;
    probeError = null;
    notifyListeners();
    try {
      nodeStatus = await flow.probe(t, adminPassword);
      // Best effort: the handshake is what makes a delta base exact, but a
      // node without it still updates (its `running=` stamp is the fallback).
      nodeInfo = nodeStatus == null ? null : await flow.tryNodeInfo(t);
      if (nodeStatus == null) {
        probeError = 'This firmware does not speak the ota CLI '
            '(expected a fork lora-ota build, e.g. Xiao_S3_WIO_repeater-*-lora-ota).';
      }
    } catch (e) {
      nodeStatus = null;
      nodeInfo = null;
      probeError = '$e';
    } finally {
      probing = false;
      notifyListeners();
    }
  }

  // ---------------- firmware selection ----------------

  Future<void> loadCatalog({bool forceRefresh = false}) async {
    catalogLoading = true;
    catalogError = null;
    notifyListeners();
    try {
      final source = await _openSource();
      catalog = await source.catalog(forceRefresh: forceRefresh);
      catalogFromCache = catalog!.fromCache;
    } catch (e) {
      catalog = null;
      catalogError = '$e';
    } finally {
      catalogLoading = false;
      notifyListeners();
    }
  }

  void toggleDevReleases(bool value) {
    showDevReleases = value;
    notifyListeners();
  }

  Future<void> refreshLibrary() async {
    libraryLoading = true;
    notifyListeners();
    try {
      final lib = await _openLibrary();
      libraryEntries = await lib.list();
    } finally {
      libraryLoading = false;
      notifyListeners();
    }
  }

  /// The releases visible to the picker, grouped by channel.
  List<FirmwareRelease> get visibleReleases {
    final all = catalog?.releases ?? const [];
    final out = all.where((r) {
      if (!showDevReleases && r.isDevTrack) return false;
      return r.appImages.isNotEmpty;
    }).toList()
      ..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
    // stable first, then dev builds
    out.sort((a, b) {
      if (a.isDevTrack == b.isDevTrack) {
        return b.publishedAt.compareTo(a.publishedAt);
      }
      return a.isDevTrack ? 1 : -1;
    });
    return out;
  }

  /// Select a GitHub asset and load (download) its bytes.
  Future<void> selectAsset(FirmwareAsset asset) async {
    selectedAsset = asset;
    selectedLibraryEntry = null;
    _selectedImage = null;
    deltaResult = null;
    imageLoading = true;
    imageError = null;
    downloadProgress = null;
    notifyListeners();
    try {
      final source = await _openSource();
      final bytes = await source.downloadAsset(asset);
      _selectedImage = bytes;
      final lib = await _openLibrary();
      // Keep the release image in the library for reuse as a delta base.
      final entry = await lib.importBytes(
        bytes,
        env: asset.env,
        version: asset.version,
        origin: 'github',
        fileName: asset.name,
      );
      libraryEntries = await lib.list();
      LibraryEntry? selected;
      for (final e in libraryEntries) {
        if (e.id == entry.id) selected = e;
      }
      selectedLibraryEntry = selected;
      await _matchBase();
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      downloadProgress = null;
      notifyListeners();
    }
  }

  /// Select a library entry for install (offline mode).
  Future<void> selectLibraryEntryForUpdate(LibraryEntry entry) async {
    selectedLibraryEntry = entry;
    selectedAsset = null;
    _selectedImage = null;
    deltaResult = null;
    imageLoading = true;
    imageError = null;
    notifyListeners();
    try {
      final lib = await _openLibrary();
      _selectedImage = await lib.read(entry);
      await _matchBase();
    } catch (e) {
      imageError = '$e';
      _selectedImage = null;
    } finally {
      imageLoading = false;
      notifyListeners();
    }
  }

  /// Compute the delta against the matched base, if any.
  Future<void> _matchBase() async {
    final status = nodeStatus;
    final image = _selectedImage;
    deltaResult = null;
    baseEntry = null;
    if (status == null || image == null) {
      notifyListeners();
      return;
    }
    final lib = await _openLibrary();
    final env = selectedEnvironment;
    // The handshake's full SHA-256 identifies the running bytes exactly, so
    // prefer it: two builds of one commit can share a version stamp and still
    // differ. The stamp stays as the fallback for pre-handshake firmware.
    final info = nodeInfo;
    baseEntry =
        info == null ? null : await lib.findBaseForSha(info.runningSha256);
    if (baseEntry == null && env != null) {
      baseEntry =
          await lib.findBaseFor(env: env, runningVersion: status.running);
    }
    if (baseEntry != null) {
      try {
        final baseBytes = await lib.read(baseEntry!);
        deltaResult = computeDelta(baseBytes, image);
      } catch (_) {
        baseEntry = null; // unreadable base: fall back to full image
        deltaResult = null;
      }
    }
    notifyListeners();
  }

  /// Environment of the current selection (asset env or library env).
  String? get selectedEnvironment =>
      selectedAsset?.env ?? selectedLibraryEntry?.env;

  /// Version of the current selection, full stamp.
  String? get selectedVersion =>
      selectedAsset?.version ?? selectedLibraryEntry?.version;

  /// Display version of the current selection.
  String? get selectedDisplayVersion =>
      selectedAsset?.displayVersion ?? selectedLibraryEntry?.version;

  /// Estimated transfer size: literal bytes (delta) or full image.
  int? get estimatedTransferBytes =>
      deltaResult?.literalBytes ?? _selectedImage?.length;

  /// Bytes to send total — delta estimated, or full image.
  int get transferBytesEstimate =>
      deltaResult?.literalBytes ?? _selectedImage?.length ?? 0;

  /// LoRa airtime estimate in seconds at the companion's current radio
  /// config, or null when radio params are unavailable.
  Future<int?> estimateTransferSeconds() async {
    final image = _selectedImage;
    final link = _link;
    if (image == null || link == null) return null;
    try {
      final params = await link.radioParams();
      final bytes = estimatedTransferBytes ?? image.length;
      // wire payload is literal bytes + op headers; upper-bound packets.
      final packets = (bytes / 160).ceil() + 16;
      final us = loraTimeOnAirMicros(
        payloadBytes: 175,
        spreadingFactor: params.spreadingFactor,
        bandwidthHz: params.bandwidthHz,
        codingRate: params.codingRate,
      );
      return (packets * us / 1e6).ceil();
    } catch (_) {
      return null;
    }
  }

  // ---------------- update execution ----------------

  void requestCancel() {
    cancelRequested = true;
    notifyListeners();
  }

  /// Full pipeline: stage → transfer → report ready. Throws on any failure;
  /// callers rethrow or surface via [updateError]. The caller (transfer
  /// screen) maps exceptions to UI.
  Future<void> runUpdate({required String version}) async {
    final t = target;
    final flow = _flow;
    final image = _selectedImage;
    final env = selectedEnvironment;
    if (t == null || flow == null || image == null || env == null) {
      throw StateError('update not ready');
    }
    // Resolve the route before arming so a bad manual path leaves no armed
    // staging session behind.
    final route = _routeFor(t);
    updatePhase = UpdatePhase.staging;
    log_('arming: ${image.length} bytes, version $version');
    notifyListeners();

    final targetId = targetIdForEnvironment(env);
    final stage = await flow.stage(t, image,
        version: version, expectedTargetId: targetId);
    log_(
        'armed: size=${stage.size} token=${stage.token.toRadixString(16).padLeft(8, '0')}');

    List<DeltaOp> ops;
    if (baseEntry != null) {
      final lib = await _openLibrary();
      final baseBytes = await lib.read(baseEntry!);
      ops = computeDelta(baseBytes, image).ops;
      log_(
          'delta: ${deltaResult?.copyBytes ?? 0} bytes reused, ${deltaResult?.literalBytes ?? 0} to send');
    } else {
      ops = computeDelta(Uint8List(0), image).ops;
      log_('full image: ${image.length} bytes');
    }

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

    // Confirm the staged image passed the node's SHA gate.
    await flow.awaitReady(t);
    updatePhase = UpdatePhase.readyToApply;
    log_('staged and verified — ready to apply');
    notifyListeners();
  }

  /// Commit: `ota apply` → node reboots into the new image.
  Future<void> applyAndVerify({required String expectedVersion}) async {
    final t = target;
    final flow = _flow;
    if (t == null || flow == null) throw StateError('no target');
    updatePhase = UpdatePhase.applying;
    notifyListeners();
    await flow.apply(t);
    log_('applied — node is rebooting');
    updatePhase = UpdatePhase.verifying;
    verifyStateKnown = false;
    verifyMatched = false;
    notifyListeners();
    final ok = await flow.awaitVersion(t, adminPassword, expectedVersion);
    verifyStateKnown = true;
    verifyMatched = ok;
    updatePhase = ok ? UpdatePhase.done : UpdatePhase.failed;
    notifyListeners();
  }

  /// Roll back the freshly applied update. We cannot know the previous
  /// version string on this node, so "verified" after a rollback means
  /// only that the node answered admin CLI again.
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
    updatePhase = UpdatePhase.done;
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

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List sha256List(List<int> data) =>
      Uint8List.fromList(sha256.convert(data).bytes);
}
