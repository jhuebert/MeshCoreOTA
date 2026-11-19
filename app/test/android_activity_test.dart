import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The launcher activity is referenced by a relative name in the manifest, so
/// it is resolved against Gradle's `namespace`. If the Kotlin/Java class lives
/// in a different package the APK still builds, but every launch dies with
/// `ClassNotFoundException` before Flutter starts. Keep all three in sync.
void main() {
  test('the manifest launcher activity matches the MainActivity source',
      () async {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();

    final namespace =
        RegExp(r'namespace\s*=\s*"([^"]+)"').firstMatch(gradle)?.group(1);
    expect(namespace, isNotNull, reason: 'Gradle namespace must be declared');

    final activityName =
        RegExp(r'android:name="\.([^"]+)"').firstMatch(manifest)?.group(1);
    expect(activityName, 'MainActivity',
        reason: 'the manifest must declare the relative launcher activity');

    final sources = <File>[
      for (final dir in [
        'android/app/src/main/kotlin',
        'android/app/src/main/java'
      ])
        if (Directory(dir).existsSync())
          ...Directory(dir).listSync(recursive: true).whereType<File>().where(
              (f) =>
                  f.path.endsWith('$activityName.kt') ||
                  f.path.endsWith('$activityName.java')),
    ];
    expect(sources, hasLength(1),
        reason: 'exactly one $activityName source file must exist');

    expect(sources.single.readAsStringSync(), contains('package $namespace'),
        reason: '$activityName must be in the Gradle namespace $namespace');
  });
}
