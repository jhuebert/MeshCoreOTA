import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/capability_service.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';
import 'package:repeater_core/repeater_core.dart';

Contact _contact() => Contact(publicKey: Uint8List.fromList(List.filled(32, 3)));

Map<String, String> _forkReplies() => {
      'ota status': 'running=v1 sha=aa state=idle',
      'filter': 'Err - usage: on|off|add',
      'fleet': 'Err - usage: on|off|chan',
      'radio2 status': 'off; preset=915,250,10,5',
      'get mqtt.status': 'mqtt wifi:up time:ok',
      'battery': 'batt 4100mV; gate off',
      'clock mesh': 'on samples=10',
      'bot': 'bot: on/off, name',
      'get cpu.freq': '> 240 Mhz',
      'get radio.rxps': '> desired=on,effective=on',
    };

void main() {
  group('CapabilityService', () {
    test('probes the core set, then extras only for a fork', () async {
      final replies = _forkReplies();
      final seen = <String>[];
      final cli = CliService(
        exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
          seen.add(command);
          return replies[command] ?? 'Unknown command';
        },
        binary: (_, __, {data = const [], required exactLength, timeout = const Duration(seconds: 10)}) async {
          throw const RepeaterRequestException('not used');
        },
      );
      final caps = await CapabilityService(cli).identify(_contact());
      expect(caps.firmwareKind, FirmwareKind.fork);
      expect(caps.confidence, CapabilityConfidence.confirmed);
      expect(caps.ota, isTrue);
      expect(caps.batteryGate, isTrue);
      expect(caps.meshClock, isTrue);
      expect(seen, containsAll(coreProbes));
      expect(seen, containsAll(extraProbes));
    });

    test('a stock node is not probed for fork extras', () async {
      final seen = <String>[];
      final cli = CliService(
        exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
          seen.add(command);
          return 'Unknown command';
        },
        binary: (_, __, {data = const [], required exactLength, timeout = const Duration(seconds: 10)}) async {
          throw const RepeaterRequestException('not used');
        },
      );
      final caps = await CapabilityService(cli).identify(_contact());
      expect(caps.firmwareKind, FirmwareKind.stock);
      expect(seen, isNot(contains('battery')));
      expect(seen.length, coreProbes.length);
    });

    test('cached results avoid any mesh traffic on the next open', () async {
      final dir = Directory.systemTemp.createTempSync('capability_cache_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cache = RepeaterCacheStore(File('${dir.path}/cache.json'));
      await cache.load();
      var calls = 0;
      final cli = CliService(
        exchange: (_, command, {timeout = const Duration(seconds: 45)}) async {
          calls++;
          return _forkReplies()[command] ?? 'Unknown command';
        },
        binary: (_, __, {data = const [], required exactLength, timeout = const Duration(seconds: 10)}) async {
          throw const RepeaterRequestException('not used');
        },
      );
      final service = CapabilityService(cli, cacheFor: (_) => cache);
      final first = await service.identify(_contact());
      expect(calls, greaterThan(0));
      final cachedCalls = calls;
      final second = await service.identify(_contact());
      expect(calls, cachedCalls);
      expect(second.firmwareKind, first.firmwareKind);
      expect(second.batteryGate, first.batteryGate);

      final forced = await service.identify(_contact(), force: true);
      expect(calls, greaterThan(cachedCalls));
      expect(forced.firmwareKind, FirmwareKind.fork);
    });

    test('lost replies leave capabilities unconfirmed', () async {
      final silent = CliService(
        exchange: (_, __, {timeout = const Duration(seconds: 45)}) async {
          throw CompanionTimeoutException('no answer');
        },
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw const RepeaterRequestException('not used');
        },
      );
      final caps = await CapabilityService(silent).identify(_contact());
      expect(caps.firmwareKind, FirmwareKind.unknown);
      expect(caps.confidence, CapabilityConfidence.unknown);
      expect(caps.supports('filter'), isFalse);
    });
  });
}
