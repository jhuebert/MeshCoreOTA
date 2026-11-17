# Agent Guide — MeshCoreOTA

## Project

Standalone Android-first Flutter/Dart app that pushes firmware updates to
MeshCore repeaters over LoRa through a stock companion device. The app talks
to the companion over BLE or TCP and uses it purely as a radio; the encrypted
OTA ops ride the same REQ/RESPONSE path as an admin `ota status` request. The
app/product name is **MeshCoreOTA**. iOS is deferred until there is hardware
to test on; Windows, macOS and Linux desktop builds use the same TCP path.

This is a personal project under `jhuebert/MeshCoreOTA`. The repeater side of
the feature lives in the `lora-ota` branch of `jhuebert/MeshCore`
(`examples/simple_repeater/OtaUpdate.*`), and the two halves must stay in
sync. The reference repos in the workspace (`MeshCore/`, `MeshChameleon/`,
`openhop_core/`) are read-only: do not edit them as part of this project.
`mesh_protocol`, `device_link` and `test_support` are reused from
MeshChameleon via `git subtree`; prefer fixing bugs upstream there (via
subtree) over diverging, retain MIT attribution, and keep `ATTRIBUTION.md`
accurate.

## Before starting work

1. Read `README.md` (the user guide) and this file. `SECURITY.md` has the
   threat model, `CHANGELOG.md` every user-visible change, and
   `docs/releasing.md` the release procedure.
2. Check `git status` before editing and leave unrelated work alone.
3. Inspect the relevant package code and the fork's `OtaUpdate.h` before
   changing anything that touches the wire contract.
4. The offline library and settings are persisted user data. A layout change
   must migrate the previous format and be tested with old-format fixtures;
   never silently discard images or the offline flag.

## Repository layout

- `app/` — Flutter UI, screens, orchestration, theme, app icon and desktop
  runners (Android, Linux, Windows, macOS).
- `app/test/` — widget and pure-Dart app tests. `support.dart` has the shared
  fixtures (`FakeLibrary`, `Catalog`, `OtaStatus`/`OtaNodeInfo`); use it for
  every screen test instead of touching platform plugins.
- `packages/ota_core/` — the wire contract (op frames, CRC), the frozen `ota
  status` CLI-line parser, `OP_INFO` parsing, the delta engine (rolling-hash
  matcher), and the windowed transfer engine (REQ/RESPONSE, op retry from
  `next_expected`).
- `packages/mesh_protocol/` — pure-Dart protocol constants, codecs, identity,
  crypto, packet models/builders (MeshChameleon subtree).
- `packages/device_link/` — pure-Dart `RadioLink` SPI, TCP/BLE/fake transports,
  binary requests (MeshChameleon subtree).
- `packages/companion_client/` — contacts, login, `remoteCli`, message pump.
- `packages/test_support/` — dev-only framed TCP client and test plumbing
  (MeshChameleon subtree).
- `bench/` — hardware harness (never run in CI):
  `--scenario probe|measure|full|delta|reject|cancel|rollback`.
- `scripts/check.sh` — the full analysis and test gate; `scripts/coverage.sh`
  adds the coverage gate; `scripts/build.sh` injects build metadata.
- `.github/workflows/ci.yml` — the gate plus platform builds;
  `release.yml` — the manual signed release.

Keep protocol/core packages free of Flutter or platform imports. Platform code
belongs in `app/`.

## Current state and next milestone

The full flow is implemented and hardware-exercised: connect, pick a repeater,
admin/ACL login, `OP_INFO` handshake, board-scoped version picker, delta or
full-image staging, windowed transfer, `ota apply`, post-reboot verification
and `ota rollback`. The app also carries a version-based offline library, a
three-way radio plan (live mesh / temporary private preset / the repeater's
radio2), and manual before/after images for custom builds.

Planned and explicitly deferred:

- iOS (needs hardware).
- Refusing a release older than the OTA feature (there are currently no such
  releases in the field, so the check has nothing to test against yet).
- macOS/Windows code signing and notarization (the builds are unsigned; users
  bypass Gatekeeper/SmartScreen explicitly).

Do not claim hardware validation unless it was run against real hardware.
Transfer robustness, radio restore and the boot rollback have been exercised
on the bench; long multi-hop transfers in the field remain empirical.

## Stock-firmware parity

- The companion is **stock**. Do not require a custom companion firmware or a
  new payload type. The app uses `CMD_SEND_BINARY_REQ` (the same path as a
  status request), `CMD_SEND_LOGIN`, `CMD_SEND_TXT_MSG` and
  `CMD_RUN_CLI_COMMAND` as shipped.
- Match `MeshCore/docs/companion_protocol.md` and the pinned stock firmware
  (`MeshCore/examples/companion_radio/`) for frame layouts, command lengths,
  response codes and limits.
- Firmware parity for the target node is the fork's `OtaUpdate.h`: the app is
  a client of that contract, not a second implementation of it.

### Known intentional differences

- A blank admin password is sent as a valid login. Stock firmware treats a
  blank password as "is this key already in my ACL?"; the app exposes that
  instead of refusing empty input.
- The app re-reads and re-sends `tempradio` on the companion to restore it
  early rather than waiting out the timer. The command is the stock CLI.
- The picker scopes to the node's reported board, even though a user may
  deliberately choose another board (the node refuses a mismatch at staging).
- The offline library stores whole versions (all boards), not a per-device
  selection; that is the product decision, not a protocol constraint.

## The OTA wire contract — stability rules

`packages/ota_core/lib/src/wire.dart` mirrors
`examples/simple_repeater/OtaUpdate.h`; `OtaUpdate.h` is the authoritative
spec.

- The op stream rides inside ordinary admin REQ/RESPONSE datagrams:
  `[tag(4)][REQ_TYPE_OTA (1)][frame_len(1)][OTA frame]`. The crypto layer
  zero-pads the plaintext to a 16-byte block, hence `frame_len` — the node
  slices exactly that many bytes and ignores the padding. Nothing else about
  the frame is negotiated: magic `O`,`T`, CRC-16/CCITT-FALSE, frozen CRC and
  op order.
- `OP_INFO` (0x07) is the capability handshake — answered in every state.
  `OP_INFO_REPORT` (0x08) carries wire version, target id, slot size,
  `max_literal`, the feature bits (`supportsDelta`, `supportsApply`), the
  running firmware version (NUL-padded 32 bytes) and the **running image's
  SHA-256** — taken over exactly the bytes an update wrote (image length from
  the ESP image header, appended digest included), so it equals the hash of
  the app's own `.bin`. That hash, not the version stamp, is the delta base
  identity: two builds of one commit share a stamp and can still differ.
  All zeros means "cannot tell" (no readable image).
- `target id` is the **build environment** id (`sha256(pio_env)[0..3]`), not a
  hardware id. The app maps it back to an environment by hashing the names it
  knows from the catalog and library. Flashing a node with another variant of
  the same board (e.g. `_observer` ↔ plain) is refused by the node and by
  `stage()` — switch variants over USB/Wi-Fi, not OTA.
- `max_literal` counts the REQ envelope: `REQ_TYPE_OTA` + `frame_len` + the op
  frame overhead + the literal's length word all come out of one
  `MAX_PACKET_PAYLOAD` datagram (173 bytes with the current 184-byte payload).
- `PUSH_CODE_BINARY_RESPONSE` (0x8C) payloads arrive zero-padded to a 16-byte
  block; `unpadFrame()` trims them by CRC, so a report whose CRC ends in `0x00`
  still parses. Two record layouts exist (tag first, or pubkey prefix then
  tag); both are accepted, and the tag-at-2 candidate must frame before it is
  believed.
- New ops get new codes; existing ops never change meaning, field order or
  size; the SEQ rules and CRC are frozen. Hard breaks are a new REQ code,
  never a silent redefinition.
- Unknown ops are dropped silently; a stray unknown op **inside a staged
  stream aborts staging** — that is deliberate.
- Don't reintroduce transport bindings ("wire v2") in docs/comments: nodes in
  the field predate any release, so this transport IS the format. Refer to it
  as the OTA wire contract.

## App UX contract

The app is a seven-step wizard: Connect → Repeater → Admin → Firmware →
Review → Transfer → Verify. Every screen carries `WizardBar` (step + label);
the next action lives in a `WizardFooter` or an equivalent bottom bar. Keep
the flow linear — an action that belongs on the next screen does not belong
below the fold on the current one.

- **Connect**: BLE is Android/iOS only; TCP is a first-class path on every
  platform (Wi-Fi/Ethernet companion, serial-to-TCP bridge, local simulator).
  The firmware library is reachable here before any connection.
- **Repeater**: repeaters and the manual public key are separate tabs. Long
  contact lists must never hide the key field or the admin login.
- **Admin**: the password is optional (see parity above), and `Check node`
  must always be tappable; do not gate it on a non-empty password.
- **Firmware**: versions are the unit. The GitHub tab shows one row per
  version — no board dropdown, no per-device rows; the app detects the
  node's board and downloads that board's image just-in-time when a version
  is tapped. Releases with no image for the detected board are hidden. The
  save button downloads **all** assets of a release (every board); the cloud
  icon shows the version's save state (not saved / partial / saved) and a
  trash icon deletes the whole version (the delta base and any selected
  image are repaired). There is no Offline tab: offline mode shows only
  saved versions in the GitHub tab. Imported `.bin` files live on the
  Imported tab — one row per file — and match by SHA-256 like any other
  entry (delta base and update image alike). The **Firmware library** on
  the main screen is this same screen in manager mode
  (`FirmwareScreen(updateMode: false)`): tapping a version downloads the
  whole version instead of selecting an update. The offline switch is
  persisted and must prevent every GitHub request (catalog included).
- **Review**: three radio plans (live mesh with the path override, temporary
  private preset on both ends, or the repeater's radio2) and before/after
  image selection. Off-mesh modes are implicit zero-hop. Show the plan's
  validation before the Start button, and never start with an invalid one.
- **Transfer/Verify**: no screen may claim success until the node answers the
  new version. A lost reply from `ota apply`/`rollback` is an unknown outcome,
  decided by re-login and `version`.

### Radio plan rules

- A temporary preset is `tempradio <freq>,<bw>,<sf>,<cr>,<minutes>` on both
  the repeater and the companion; both revert after the timer (the app
  restores the companion early and sends the live preset back to the node).
- radio2 is `radio2 <freq>,<bw>,<sf>,<cr>`; the node's primary keeps serving
  the mesh and the companion is moved to the secondary for the transfer. It
  must not overlap the live band (half of each bandwidth plus the 6 kHz
  guard) and must be scannable — the node validates; the app mirrors the
  overlap rule and surfaces the node's refusal.
- If radio2 is already enabled, do **not** reconfigure it: the operator
  enters the secondary preset it already uses, the app only tunes the
  companion, and the node's configuration is left alone. If the app enabled
  radio2 for the update, it turns it off again afterwards.
- Both firmware CLIs defer the retune ~2 s so their reply leaves first; wait
  ~3 s after arming the plan before sending ops.
- Restore the radios **before** the operator commits: apply and verification
  belong on the live mesh.

## Development and verification

Flutter stable / Dart are expected on `PATH`.

Run all checks from the repo root:

```sh
./scripts/check.sh      # format, analyze, all package + app tests
./scripts/coverage.sh   # the same with coverage; coverage_baseline.json is the gate
```

`DART` / `FLUTTER` override the executables. CI runs both, then builds the
APKs and the Linux/Windows/macOS desktop bundles.

New source files need ≥80% line coverage, and an existing file may not lose
covered lines. Regenerate the baseline with
`./scripts/coverage.sh --write-baseline` only after landing real coverage
gains. Every behavior change needs tests added in the same commit; every bug
fix needs a test that reproduces it.

The app's widget tests must not touch platform plugins or the network. Use
`test/support.dart` (`FakeLibrary`, fixture `Catalog`/`OtaStatus`/`OtaNodeInfo`)
and pump screens with a populated `AppState` — path_provider and HTTP are not
available in the test binding, and a real I/O call hangs the fake-async zone.

When the wire contract or the firmware side changes, run the fork's native
suite too:

```sh
cd ../MeshCore && pio test -e native_ota
```

The app icon is `app/assets/icon/icon.svg` (source) rendered to `icon.png`;
regenerate the platform icons with `cd app && dart run flutter_launcher_icons`.

## Protocol constraints and known gotchas

- Companion transport frames are `'<'` + uint16 LE length + payload inbound
  and `'>' + uint16 LE length + payload` outbound. The 1.18 `MAX_FRAME_SIZE`
  is **176 payload bytes** excluding the 3-byte TCP header. BLE NUS carries a
  raw payload per write/notify, also ≤176. A command over the frame limit is
  silently dropped by the companion — an oversized op is a stalled transfer,
  not an error. `otaLiteralChunkForBinaryReq()` derives the chunk size.
- `SELF_INFO` and `CMD_SET_RADIO_PARAMS` frequency fields are in **kHz** on
  the wire, while bandwidth is in **Hz**. `RadioParams.frequencyHz` is
  normalized to Hz; the CLI (`get radio`, `tempradio`, `radio2`) uses MHz and
  kHz strings. Convert only at the boundaries.
- `CMD_DEVICE_QUERY` reports `max_contacts / 2` in one byte; the client clamps
  its reported contacts.
- `app_target_ver >= 3` selects the V3 direct/channel message response layout;
  preserve the value sent by the client in `DEVICE_QUERY`.
- `PUSH_CODE_LOG_RX_DATA (0x88)` is `[code][snr*4][rssi][raw on-air packet]`.
- A message-sync pump drains unrelated queued messages before a CLI reply;
  `remoteCli` filters by sender prefix and text type, and `drainMessages()`
  clears stale replies at session start.
- Android BLE display names: prefer `ScanResult.advertisementData.advName`
  over `platformName` (a stale MAC-derived GAP cache).
- Never log private identity key material. The app holds no repeater keys;
  the admin password is session-only and never persisted.
- A transfer can be minutes long and the mesh can lose a reply. Treat
  uncertainty as unknown, never as success; verify by re-reading the node.

## Bench/live-mesh coupling

- The bench drives real radios through TCP companions; zero-hop and
  multi-hop (`--path`) are both supported.
- When running against the live mesh, keep traffic minimal: read-only
  `probe`, one-byte stage/abort cycles, and DIRECT paths when possible.
  Restore the companion's contact path to zero-hop when done.
- Live-mesh tests leak into the fork's hardware — a failed flash is
  recoverable via `ota rollback` on-device, but leave the node idle and on its
  last-good image when finished.

## Change and git discipline

- Work on `main` here (this repo is mine). Commit format/analyze/test-green
  only. One concern per commit; conventional prefixes (`feat:`, `fix:`,
  `docs:`, `ci:`, `refactor:`).
- Keep changes focused and match the surrounding Dart/Flutter style
  (`dart format`). Do not upgrade dependencies as drive-by work.
- Update `CHANGELOG.md` for every user-visible behavior, and the README when
  the user-facing flow changes; `docs/releasing.md` when the pipeline changes.
- Do not create a GitHub issue, PR, release, or publish artifacts without
  Jason's explicit request. Pushing code to the personal repo is allowed when
  Jason explicitly requests it.
- The fork (`MeshCore/examples/simple_repeater/OtaUpdate.*`) is a PRIME-time
  fork: keep fork changes minimal, and always run the native OTA tests and
  the app gates together.
- Tags `x.y.z` cut releases (see `docs/releasing.md`).
