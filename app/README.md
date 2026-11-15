# MeshCoreOTA — the app

Flutter app that performs OTA firmware updates on MeshCore repeaters from a
phone (or, as a testing target, a Linux desktop). This directory is the
Flutter project; the repo root has the packages, docs and release tooling.

See the root [README](../README.md) for the design, and
[docs/releasing.md](../docs/releasing.md) for builds and signing.

- Targets: Android (releases), Linux (testing only, TCP companion).
- BLE is Android/iOS; desktop is TCP-only.
- `flutter pub get`, then `flutter analyze && flutter test`, or use the
  repo-root `./scripts/check.sh`.
