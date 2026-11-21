import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_repeater_manager/services/json_store.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('json_store_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('writes schema and reads it back', () async {
    final file = File('${dir.path}/nested/data.json');
    final store = VersionedJsonStore(file, schema: 2);
    await store.write({'offline': true});
    expect(jsonDecode(await file.readAsString())['schema'], 2);
    expect((await store.read())!['offline'], true);
  });

  test('migrates an old shape without overwriting it first', () async {
    final file = File('${dir.path}/old.json');
    await file.writeAsString(jsonEncode({'offline': true}));
    final store = VersionedJsonStore(
      file,
      schema: 2,
      migrate: (raw, from) => {'offline': raw['offline'], 'from': from},
    );
    final data = (await store.read())!;
    expect(data['schema'], 2);
    expect(data['from'], 0);
    expect(data['offline'], true);
  });

  test('a newer schema is reported, not silently overwritten', () async {
    final file = File('${dir.path}/future.json');
    await file.writeAsString(jsonEncode({'schema': 99, 'data': 'keep me'}));
    final store = VersionedJsonStore(file, schema: 2);
    expect(store.read, throwsA(isA<SchemaTooNewException>()));
    expect(await file.readAsString(), contains('keep me'));
  });
}
