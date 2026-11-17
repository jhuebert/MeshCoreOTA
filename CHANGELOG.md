# Changelog

All notable changes to MeshCoreOTA are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
[SemVer](https://semver.org/).

## [Unreleased]

### Added

- **The firmware library is now the firmware picker, usable on its own.**
  The screen reached from the main screen is the same one as step 4: the
  **GitHub** tab downloads a release version (or a single board's image),
  the **Offline** tab lists saved versions with a per-version *Delete this
  version* action, and the **Imported** tab holds imported `.bin` files —
  one row per file — with an import button. Downloaded versions and imported
  files are always separate. In the standalone view, taps download or inspect
  instead of selecting an update; inside an update they still pick the image.
- **Per-.bin and per-version deletes.** Every image can be deleted from its
  row, and a saved version can be deleted as a unit (all boards). Deleting
  the selected image or delta base clears it.


- **A guided seven-step flow.** Connect → Repeater → Admin → Firmware →
  Review → Transfer → Verify, with the same step bar and bottom action on
  every screen. The admin login moved to its own step, and the repeater list
  and manual public key are separate tabs — a long contact list no longer
  hides the fields below it.
- **Optional admin password.** A blank login is valid: the repeater checks
  whether the companion's key is already an admin in its ACL, so no password
  is needed for a provisioned companion. `Check node` is never disabled for
  an empty password.
- **Board-scoped version picker.** The node's `OP_INFO` target id is mapped
  back to its build environment; the board dropdown is alpha-sorted, prefilled
  from that, and the GitHub listing only shows images for the chosen board.
- **Stable and dev are separate tabs**, each newest-first with release dates
  (dev builds used to be a switch under one long list).
- **Version-based offline library.** Saving a version downloads every board's
  image of that release, and the Offline tab lists only saved versions (with
  a complete/partial marker). A persistent **Go offline** switch on the
  firmware screen prevents *every* GitHub request, including the catalog.
- **Three radio plans.** Live mesh with the DIRECT path override; a temporary
  private preset on both the repeater and the companion; or the repeater's
  radio2 preset while the live mesh keeps running. Off-mesh modes are zero-hop,
  and a settings screen suggests a preset and a duration from the node's radio
  and the transfer estimate. An existing radio2 configuration is reported and
  left untouched.
- **Before/after image selection.** Choose the delta base explicitly (or force
  a full image), and import custom `.bin` builds on any platform. A custom
  image uses the board id the node itself reported.
- **Windows and macOS desktop builds**, alongside Linux; the release workflow
  attaches all three to the GitHub Release. TCP is a first-class transport on
  every platform, including file import/export on desktop.
- **App icon.** A repeater-and-update-loop launcher icon (generated from
  `app/assets/icon/icon.svg`) and a user-guide README with screenshots.

- **OP_INFO handshake.** The app now asks the node for its capabilities
  before arming: wire version, board target id, slot size, `max_literal`,
  and the feature bits (`supportsDelta`, `supportsApply`), plus the running
  firmware version and the running image's SHA-256 (`OtaNodeInfo`,
  `queryNodeInfo`). `UpdateFlow.stage` takes an optional `expectedTargetId`
  and refuses a definitive board mismatch before registering an arm; a node
  that does not answer is treated as unknown and proceeds as before (the
  SHA gate still protects the flash). `bench --scenario probe` prints the
  handshake too.
- **Board-mismatch fast fail.** `runUpdate` passes the selected environment's
  target id into `stage()`; a node reporting a different board id aborts
  staging with `UpdateFlowException` before any arm is registered.
- **Delta base by exact image hash.** The library now matches bases with
  `FirmwareLibrary.findBaseForSha()` against the handshake's running-image
  SHA-256 first, and only falls back to the `running=` version stamp. Two
  builds of one commit share a stamp and can still differ (the build date is
  embedded), which silently broke a delta and burned the whole transfer
  before the device's SHA gate rejected it.
- **The node's reported SHA-256 is the `.bin` hash.** It is taken over exactly
  the bytes an update wrote (length from the ESP image header, appended
  digest included) instead of over the whole erase-filled partition, so it
  is comparable with the app's own images (`ota status` reports the same
  hash).
- **RESPONSE padding is handled by CRC.** `PUSH_CODE_BINARY_RESPONSE` payloads
  arrive zero-padded to a 16-byte block; the parser now trims by trying frame
  CRCs instead of assuming the frame ends at the last non-zero byte (which
  broke reports whose CRC ends in `0x00`, and every report larger than one
  block, including `OP_INFO_REPORT`).

### Removed

- **The field pack.** The library screen's `.zip` import/export is gone. Move
  images between devices by importing the `.bin` files directly (one at a
  time, on any platform, including desktop) or by re-downloading the version.

### Changed

- **The OTA wire contract: ops now ride ordinary REQ/RESPONSE datagrams.**
  Each op is sent as `CMD_SEND_BINARY_REQ`
  (`[pub_key][REQ_TYPE_OTA][frame_len][op frame]`) to the companion, which
  encrypts it as an ordinary direct REQ to the node; the
  OP_REPORT comes back inside the RESPONSE as `PUSH_CODE_BINARY_RESPONSE`.
  Intermediate nodes forward them without any custom firmware. **Requires the
  matching fork firmware** — nodes running the earlier raw-custom build are
  not compatible with this app version.
- `OP_ASK` carries no body; the report rides the standard REQ reply routing.
  The transfer engine requires a `contact` (binary requests are addressed to
  the companion's saved record for it).
- Literal chunk size for stock companions is 132 bytes (the frame limit less
  the binary-request envelope and the `frame_len` byte).
- `parseBinaryResponse` is now shared between transfer/resume code and the
  new handshake; the two `PUSH_CODE_BINARY_RESPONSE` layouts seen in the
  field (old tag-first, current pubkey-then-tag) both parse.
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
  WiFi/Ethernet companion or simulator; BLE stays mobile-only (library
  browse/delete/import work everywhere), no foreground service on desktop.
- Repeater picker: companion contacts (repeater-filtered, manual pubkey
  entry), admin login, `ota status` probe.
- Firmware sources: fork GitHub releases (stable + dev track) with optional
  SHA256SUMS verification; offline library of downloaded versions.
- Delta updates by default (rolling-hash matcher, full-position index);
  full-image fallback; airtime estimate at the companion's radio config.
- Windowed op-stream transfer with OP_ASK/OP_REPORT recovery; cancel =
  `ota abort` (safe).
- `ota apply` commit step, post-reboot re-login and `version` verification,
  and one-button `ota rollback`.
- CI (analyze/test/coverage/APKs) and signed release pipeline
  (see `docs/releasing.md`).
