import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';
import 'package:meshcore_repeater_manager/services/repeater_directory.dart';
import 'package:repeater_core/repeater_core.dart';

void main() {
  late Directory dir;
  late RepeaterDirectory directory;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('directory_test');
    directory = RepeaterDirectory(dir);
    await directory.load();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  RepeaterProfile profile(String hex, String name) => RepeaterProfile(
        publicKeyHex: hex,
        name: name,
        tags: const ['north'],
        capabilities: RepeaterCapabilities(
          firmwareKind: FirmwareKind.fork,
          confidence: CapabilityConfidence.confirmed,
          ota: true,
        ),
      );

  test('saves and lists profiles by public key', () async {
    await directory.upsert(profile('aa' * 32, 'Roof'));
    await directory.upsert(profile('bb' * 32, 'Hill'));
    expect(directory.profiles, hasLength(2));
    expect(directory.get('AA' * 32)!.name, 'Roof');
    expect(directory.profiles.first.lastSeen, isNotNull);
  });

  test('folders use a hash of the key, never the key itself', () async {
    final hex = 'cc' * 32;
    final folder = directory.folderFor(hex).path;
    expect(folder, isNot(contains(hex)));
    await directory.upsert(profile(hex, 'Roof'));
    expect(File('${directory.folderFor(hex).path}/profile.json')
        .existsSync(), isTrue);
  });

  test('each repeater gets its own cache store', () async {
    final cache = directory.cacheFor('dd' * 32);
    await cache.load();
    await cache.write('name', 'Roof');
    expect(cache.read('name')!.value, 'Roof');
  });

  test('an identity change moves the folder and index entry', () async {
    final old = '11' * 32;
    final next = '22' * 32;
    await directory.upsert(profile(old, 'Roof'));
    final cache = directory.cacheFor(old);
    await cache.load();
    await cache.write('radio', '915,250,10,5');

    await directory.migrateIdentity(old, next);

    expect(directory.get(old), isNull);
    expect(directory.get(next)!.name, 'Roof');
    expect(directory.cacheFor(next).read, isNotNull);
    final moved = RepeaterCacheStore(
        File('${directory.folderFor(next).path}/cache.json'));
    await moved.load();
    expect(moved.read('radio')!.value, '915,250,10,5');
    expect(directory.pendingIdentity, isNull);
  });

  test('an old index shape is migrated', () async {
    await File('${dir.path}/index.json').writeAsString(jsonEncode({
      'profiles': [
        {'publicKeyHex': '55' * 32, 'name': 'Old', 'tags': []}
      ]
    }));
    final old = RepeaterDirectory(dir);
    await old.load();
    expect(old.profiles.single.name, 'Old');
    await old.upsert(old.profiles.single);
    expect(jsonDecode(await File('${dir.path}/index.json').readAsString())[
        'schema'], 1);
  });
}
