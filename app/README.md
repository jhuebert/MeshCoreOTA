# MeshCoreRepeaterManager — the app

Flutter app that performs OTA firmware updates on MeshCore repeaters from a
phone or a computer. This directory is the Flutter project; the repo root has
the packages, docs and release tooling.

See the root [README](../README.md) for the user guide, and
[docs/releasing.md](../docs/releasing.md) for builds and signing.

- Targets: Android (the primary release), Linux, Windows and macOS. iOS is
  deferred until there is hardware to test on.
- BLE is Android/iOS only; desktop is TCP-only.
- `flutter pub get`, then `flutter analyze && flutter test`, or use the
  repo-root `./scripts/check.sh`.
- The launcher icon is `assets/icon/icon.svg` rendered to `icon.png`;
  regenerate the platform icons with `dart run flutter_launcher_icons`.
