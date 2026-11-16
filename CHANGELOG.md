# Changelog

All notable changes to MeshCoreOTA are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **OTA transport v2: ops now ride ordinary REQ/RESPONSE datagrams.** Each op
  is sent as `CMD_SEND_BINARY_REQ` (`[pub_key][REQ_TYPE_OTA][op frame]`) to
  the companion, which encrypts it as an ordinary direct REQ to the node; the
  OP_REPORT comes back inside the RESPONSE as `PUSH_CODE_BINARY_RESPONSE`.
  Intermediate nodes forward them without any custom firmware. **Requires the
  matching v2 fork firmware** — nodes running the earlier raw-custom build are
  not compatible with this app version.
- `OP_ASK` no longer carries a return path; the report rides the standard REQ
  reply routing. Transfer engine requires a `contact` (binary requests are
  addressed to the companion's saved record for it).
- Literal chunk size for stock companions is 133 bytes (the frame limit less
  the binary-request envelope).
- The bench's `--path` flag now pushes the path into the companion's contact
  record (like `change_path`), since binary requests carry no per-packet path.
  The app's DIRECT-path override does the same when an update starts.
- `bench/bin/probe.dart`, `probe2.dart`, `slot_probe.dart`,
  `reboot-during-stage.dart` updated to the binary-request transport.

### Added

- Initial pre-bench release. BLE (NUS) and TCP transports to a stock companion.
- `RadioLink.sendBinaryRequest` and `setContactPath` (TCP/BLE/fake): binary
  requests with contact-path override (binary framing and the companion's
  `CMD_ADD_UPDATE_CONTACT` record write).
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
- Windowed op-stream transfer with OP_ASK/OP_REPORT recovery; cancel =
  `ota abort` (safe).
- `ota apply` commit step, post-reboot re-login and `version` verification,
  and one-button `ota rollback`.
- CI (analyze/test/coverage/APKs) and signed release pipeline
  (see `docs/releasing.md`).
