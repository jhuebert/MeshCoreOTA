import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_client/companion_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshcore_repeater_manager/services/cli_service.dart';
import 'package:meshcore_repeater_manager/services/management_audit_store.dart';
import 'package:repeater_core/repeater_core.dart';

Contact _contact() =>
    Contact(publicKey: Uint8List.fromList(List.filled(32, 7)));

Uint8List _statusReport() {
  final b = ByteData(RepeaterStatus.reportLength);
  b.setUint16(0, 4300, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  group('CliService', () {
    test('serializes exchanges so the companion is never re-entered', () async {
      var busy = false;
      final gate = Completer<void>();
      final started = <String>[];
      final service = CliService(
        exchange: (target, command,
            {timeout = const Duration(seconds: 45)}) async {
          expect(busy, isFalse, reason: '$command overlapped another exchange');
          busy = true;
          started.add(command);
          try {
            if (command == 'get name') await gate.future;
            return '> ok';
          } finally {
            busy = false;
          }
        },
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw StateError('not used');
        },
      );
      final first = service.read(_contact(), 'get name');
      final second = service.read(_contact(), 'get tx');
      await Future<void>.delayed(Duration.zero);
      expect(started, ['get name']);
      gate.complete();
      await Future.wait([first, second]);
      expect(started, ['get name', 'get tx']);
    });

    test('retries an idempotent read once, then reports unknown', () async {
      var calls = 0;
      final service = CliService(
        exchange: (_, __, {timeout = const Duration(seconds: 45)}) async {
          calls++;
          throw CompanionTimeoutException('no answer');
        },
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw StateError('not used');
        },
      );
      final reply = await service.read(_contact(), 'get radio');
      expect(calls, 2);
      expect(reply.kind, CliReplyKind.unknown);
    });

    test('writes are not retried and are audited with their outcome', () async {
      final dir = Directory.systemTemp.createTempSync('cli_service_audit_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final audit = ManagementAuditStore(File('${dir.path}/audit.json'));
      await audit.load();
      var calls = 0;
      final service = CliService(
        exchange: (_, __, {timeout = const Duration(seconds: 45)}) async {
          calls++;
          throw CompanionTimeoutException('no answer');
        },
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw StateError('not used');
        },
        audit: audit,
        repeaterKeyHex: 'aa' * 32,
      );
      final reply = await service.write(_contact(), 'set password secret',
          family: 'access');
      expect(calls, 1);
      expect(reply.kind, CliReplyKind.unknown);
      expect(audit.entries().single.outcome, AuditOutcome.unknown);
      expect(audit.entries().single.command, 'set password [redacted]');
    });

    test('a batch save returns a result per key and stops on a refusal',
        () async {
      final service = CliService(
        exchange: (_, command, {timeout = const Duration(seconds: 45)}) async =>
            command.contains('flood.max') ? 'Err - bad value' : '> ok',
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw StateError('not used');
        },
      );
      final results = await service.saveSettings(
          _contact(), {'tx': '20', 'flood.max': '999', 'repeat': 'on'},
          family: 'settings');
      expect(results.keys, ['tx', 'flood.max', 'repeat']);
      expect(results['flood.max']!.kind, CliReplyKind.error);
      expect(results['repeat']!.kind, CliReplyKind.ok);
    });

    test('status uses one binary request and parses its report', () async {
      final service = CliService(
        exchange: (_, __, {timeout = const Duration(seconds: 45)}) async {
          throw StateError('not used');
        },
        binary: (_, type,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          expect(type, reqTypeGetStatus);
          expect(exactLength, RepeaterStatus.reportLength);
          return _statusReport();
        },
      );
      final status = await service.status(_contact());
      expect(status!.batteryMilliVolts, 4300);
    });

    test('a missing status reply is unknown, not zero-valued', () async {
      final service = CliService(
        exchange: (_, __, {timeout = const Duration(seconds: 45)}) async {
          throw StateError('not used');
        },
        binary: (_, __,
            {data = const [],
            required exactLength,
            timeout = const Duration(seconds: 10)}) async {
          throw const RepeaterRequestException('no reply');
        },
      );
      expect(await service.status(_contact()), isNull);
    });
  });
}
