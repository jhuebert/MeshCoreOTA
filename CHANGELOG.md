# Changelog

All notable changes to MeshCoreOTA are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[SemVer](https://semver.org/).

## [Unreleased]

### Added

- Initial pre-bench release. BLE (NUS) and TCP transports to a stock companion.
- Linux desktop build (testing target): the full OTA flow over TCP against a
  WiFi/Ethernet companion or simulator; BLE stays mobile-only, field-pack
  import/export is mobile-only (library browse/delete work everywhere), no
  foreground service on desktop.
- Repeater picker: companion contacts (repeater-filtered, manual pubkey
  entry), admin login, `ota status` probe.
- Firmware sources: fork GitHub releases (stable + dev track) with optional
  SHA256SUMS verification; offline library with field-pack export/import.
- Delta updates by default (rolling-hash matcher, full-position index);
  full-image fallback; airtime estimate at the companion's radio config.
- Windowed op-stream transfer with OP_ASK/OP_REPORT recovery; DIRECT packets
  only; cancel = `ota abort` (safe).
- `ota apply` commit step, post-reboot re-login and `version` verification,
  and one-button `ota rollback`.
- CI (analyze/test/coverage/APKs) and signed release pipeline
  (see `docs/releasing.md`).
