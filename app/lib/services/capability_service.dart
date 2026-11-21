import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:repeater_core/repeater_core.dart';

import 'cli_service.dart';
import 'repeater_cache_store.dart';

typedef CacheFor = RepeaterCacheStore? Function(Contact contact);

/// Identifies a repeater from cached, read-only probe replies. No screen ever
/// assumes a feature exists: an unconfirmed capability stays locked.
class CapabilityService {
  CapabilityService(this.cli, {this.cacheFor});

  static const _cacheKey = 'capabilities';
  static const _probeTimeout = Duration(seconds: 10);

  final CliService cli;
  final CacheFor? cacheFor;

  Future<RepeaterCapabilities> identify(
    Contact target, {
    bool force = false,
    bool otaConfirmed = false,
  }) async {
    final cache = cacheFor?.call(target);
    if (!force && cache != null) {
      await cache.load();
      final entry = cache.read(_cacheKey);
      final raw = entry?.value;
      if (raw is Map) {
        return RepeaterCapabilities.fromJson(Map<String, dynamic>.from(raw));
      }
    }

    final replies = <String, String?>{};
    for (final probe in coreProbes) {
      replies[probe] = await _probe(target, probe);
    }
    var result = detectCapabilities(
        replies: replies, otaConfirmed: otaConfirmed);
    if (result.firmwareKind == FirmwareKind.fork) {
      for (final probe in extraProbes) {
        replies[probe] = await _probe(target, probe);
      }
      result =
          detectCapabilities(replies: replies, otaConfirmed: otaConfirmed);
    }
    await cache?.write(_cacheKey, result.toJson());
    return result;
  }

  Future<String?> _probe(Contact target, String probe) async {
    final reply = await cli.read(target, probe, timeout: _probeTimeout);
    return reply.kind == CliReplyKind.unknown ? null : reply.text;
  }
}
