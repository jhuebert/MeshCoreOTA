import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/management_audit_store.dart';

void main() {
  late Directory dir;
  late ManagementAuditStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('audit_test');
    store = ManagementAuditStore(File('${dir.path}/audit.json'));
    await store.load();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('records writes with an explicit outcome', () async {
    await store.record('set tx 20',
        repeaterKeyHex: 'aa' * 32,
        family: 'settings',
        replyKind: 'ok',
        outcome: AuditOutcome.ok);
    final entries = store.entries();
    expect(entries, hasLength(1));
    expect(entries.single.family, 'settings');
    expect(entries.single.outcome, AuditOutcome.ok);
    expect(entries.single.command, 'set tx 20');
  });

  test('secrets are redacted before they reach disk', () async {
    await store.record(
        'set password hunter2; set guest.password secret; '
        'set mqtt2.token abc123; set prv.key deadbeef',
        repeaterKeyHex: 'bb' * 32,
        family: 'access',
        replyKind: 'rebootNeeded',
        outcome: AuditOutcome.rebootNeeded);
    final command = store.entries().single.command;
    expect(command, isNot(contains('hunter2')));
    expect(command, isNot(contains('secret')));
    expect(command, isNot(contains('abc123')));
    expect(command, isNot(contains('deadbeef')));
    expect(store.export(), isNot(contains('hunter2')));
  });

  test('filters by repeater and newest first', () async {
    for (final (hex, family) in [
      ('aa' * 32, 'radio'),
      ('bb' * 32, 'settings'),
      ('aa' * 32, 'access'),
    ]) {
      await store.record('set tx 20',
          repeaterKeyHex: hex,
          family: family,
          replyKind: 'ok',
          outcome: AuditOutcome.ok);
    }
    expect(store.entries(repeaterKeyHex: 'AA' * 32).map((e) => e.family),
        ['access', 'radio']);
    expect(store.entries(limit: 1).single.family, 'access');
  });

  test('entries survive a reload and export as redacted JSON', () async {
    await store.record('set guest.password hunter2',
        repeaterKeyHex: 'dd' * 32,
        family: 'access',
        replyKind: 'rebootNeeded',
        outcome: AuditOutcome.rebootNeeded);
    final reopened = ManagementAuditStore(File('${dir.path}/audit.json'));
    await reopened.load();
    expect(reopened.entries().single.command, 'set guest.password [redacted]');

    final decoded = jsonDecode(reopened.export()) as List;
    expect(decoded, hasLength(1));
    expect(decoded.single['outcome'], 'rebootNeeded');
    expect(reopened.export(), isNot(contains('hunter2')));
  });

  test('bare password and wifi keys are redacted too', () async {
    expect(ManagementAuditStore.redactCommand('password hunter2'),
        'password [redacted]');
    expect(ManagementAuditStore.redactCommand('set wifi.pwd abc'),
        'set wifi.pwd [redacted]');
    // Ordinary settings are never masked.
    expect(ManagementAuditStore.redactCommand('set tx 20'), 'set tx 20');
  });

  test('clear empties the log', () async {
    await store.record('set tx 20',
        repeaterKeyHex: 'ee' * 32,
        family: 'settings',
        replyKind: 'ok',
        outcome: AuditOutcome.ok);
    await store.clear();
    expect(store.entries(), isEmpty);
  });

  test('keeps only the most recent 1000 entries', () async {
    for (var i = 0; i < ManagementAuditStore.maxEntries + 10; i++) {
      await store.record('set tx $i',
          repeaterKeyHex: 'cc' * 32,
          family: 'settings',
          replyKind: 'ok',
          outcome: AuditOutcome.unknown);
    }
    expect(store.entries(), hasLength(ManagementAuditStore.maxEntries));
    expect(store.entries(limit: 1).single.command,
        'set tx ${ManagementAuditStore.maxEntries + 9}');
  });
}
