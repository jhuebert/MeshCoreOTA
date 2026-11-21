import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/repeater_cache_store.dart';

void main() {
  late Directory dir;
  late File file;
  late RepeaterCacheStore store;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('cache_test');
    file = File('${dir.path}/cache.json');
    store = RepeaterCacheStore(file);
    await store.load();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('a fresh cache has no values', () {
    expect(store.read('radio'), isNull);
  });

  test('writes are labelled with source and time', () async {
    final at = DateTime.utc(2026, 11, 20);
    await store.write('radio', '915,250,10,5', at: at);
    final entry = store.read('radio')!;
    expect(entry.value, '915,250,10,5');
    expect(entry.source, CacheSource.remote);
    expect(entry.fetchedAt, at);

    // A second load proves it was persisted, not just held in memory.
    final reopened = RepeaterCacheStore(file);
    await reopened.load();
    expect(reopened.read('radio')!.value, '915,250,10,5');
  });

  test('a failed write keeps the value but marks it stale', () async {
    await store.write('tx', 20, source: CacheSource.localEdit);
    await store.markStale('tx');
    final entry = store.read('tx')!;
    expect(entry.value, 20);
    expect(entry.isStale, isTrue);
  });

  test('invalidateAll clears cached values', () async {
    await store.write('name', 'Roof');
    await store.invalidateAll();
    expect(store.read('name'), isNull);
  });

  test('samples are bounded per metric', () async {
    for (var i = 0; i < RepeaterCacheStore.maxSamplesPerMetric + 5; i++) {
      await store.addSample('battery', i.toDouble(),
          at: DateTime.fromMillisecondsSinceEpoch(i));
    }
    final samples = store.samples('battery');
    expect(samples, hasLength(RepeaterCacheStore.maxSamplesPerMetric));
    expect(samples.first.value, 5.0);
    expect(samples.last.value, RepeaterCacheStore.maxSamplesPerMetric + 4.0);
  });

  test('an old bare-value cache is migrated, not discarded', () async {
    await file.writeAsString(jsonEncode({
      'values': {'radio': '915,250,10,5', 'name': 'Roof'}
    }));
    final old = RepeaterCacheStore(file);
    await old.load();
    expect(old.read('radio')!.value, '915,250,10,5');
    expect(old.read('name')!.source, CacheSource.remote);
    expect(old.read('name')!.fetchedAt,
        DateTime.fromMillisecondsSinceEpoch(0));
    await old.write('tx', 20);
    expect(jsonDecode(await file.readAsString())['schema'], 1);
    expect(jsonDecode(await file.readAsString())['values']['radio']['value'],
        '915,250,10,5');
  });
}
