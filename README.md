# MeshCoreOTA

Over-the-air firmware updates for **MeshCore repeaters** — from your phone,
over LoRa, with no laptop at the tower and no mesh flood traffic.

The app talks to a stock MeshCore companion device over BLE (Nordic UART
Service) or TCP, and uses it purely as a radio. The OTA ops ride inside
ordinary encrypted REQ/RESPONSE datagrams: each op goes out as a
`CMD_SEND_BINARY_REQ` to the companion, which encrypts it and routes it to the
repeater like any other request. Intermediate nodes only forward standard
mesh traffic, so they do not need any custom firmware — only the target
repeater runs the fork. The app picks the board, the version and the transfer
parameters; the repeater only applies ops and verifies SHA-256. Everything
else is app-side.

**Status: benched and working, pre-release.** The fork firmware implementing
the repeater side lives in `lora-ota` at
[jhuebert/MeshCore](https://github.com/jhuebert/MeshCore); the wire contract
ops ride inside ordinary encrypted REQ/RESPONSE datagrams. The full flow has
been exercised on hardware — stage, SHA gate, apply, automatic rollback — but
treat every path as field-unproven until an update has flown to a node you
did not assemble yourself. The whole flow is designed so mistakes cannot
brick a node (see "Safety model" below).

Android is the release target. iOS is not supported and is not planned until
there is hardware to test on. A Linux desktop build exists as a testing
target (TCP companions only).

## What it does

1. Connect to a companion (BLE scan, or TCP for the bench/127.0.0.1).
2. Pick a repeater from the companion's contacts, or enter its public key.
3. Sign in as repeater admin (password entered per session, never stored).
4. Pick a firmware:
   - **GitHub** — releases from the fork (`filter-vX.Y.Z` stable,
     `filter-vX.Y.Z-dev.N` dev builds). App-slot `.bin` images only —
     `-merged.bin` is never offered; OTA cannot carry a bootloader.
   - **Library** — images cached on-device, imported from a `.bin`, or from a
     "field pack" (`.zip`) exported earlier. Works with no bars.
5. Review: board, version, delta-vs-full transfer estimate with an airtime
   estimate at the companion's current radio config.
6. Transfer: windowed REQ/RESPONSE datagrams with `OP_ASK`/`OP_REPORT`
   recovery — the node re-asks for exactly what it missed. Ops ride ordinary
   mesh requests, so intermediate nodes forward them without custom firmware.
7. Commit: `ota apply` flips the boot partition and reboots. The app re-logs
   in and checks `version`. A bad image flips itself back automatically in
   the fork firmware (boot health check).
8. Undo: one button sends `ota rollback`.

Delta updates are the default: unchanged regions become `OP_COPY` ops against
the running image (matched by full version stamp — the `running=` string from
`ota status`; no base in the library → full image). The device-side SHA-256
gate decides what may boot; a wrong base fails staging at `OP_END` and the
node keeps the old image.

## Safety model (why this cannot brick a node)

- **Staged bytes are untrusted until proven.** `OP_END` does SHA-256 over the
  staged slot; mismatch → staging scrapped, `state=error`, nothing boots.
- **Nothing boots without an admin.** `ota apply` requires the same admin
  session every other repeater CLI command does.
- **New image boots, fails health check → flips back.** The fork firmware
  re-verifies LoRa init + one packet TX on the fresh boot; failure flips the
  boot partition back to the previous slot and reboots. No human intervention.
- **Ops travel as ordinary encrypted requests.** The transfer rides the same
  REQ/RESPONSE path as a status request: direct along the companion's saved
  route when it has one, flooded (like any ordinary request) when it does not.
  No special payload type crosses the mesh, and relays need no custom code.
- **The companion is stock.** No companion-firmware change; it is used exactly
  as it ships (its binary-request path, the same one status requests use).

See also `SECURITY.md` for the threat model and the fork plan documents
(`plans/2026-11-15-lora-ota-master-plan.md` in the MeshCore fork) for the
firmware side.

## Building

Flutter stable (CI pins the exact version — see
[.github/workflows/ci.yml](.github/workflows/ci.yml)). From the repo root:

```sh
./scripts/check.sh      # analyze + format + test everything
./scripts/build.sh apk --release
./scripts/build.sh linux --release
```

### Linux (testing target)

The desktop Linux build is a first-class **testing target**, not a release
artifact. It exists so the whole OTA flow can be exercised on a laptop
without installing an APK on a phone: pair it with a WiFi/Ethernet companion
(or a `127.0.0.1:5000` simulator) and drive an update over TCP.

Notes:

- **BLE companion support is Android/iOS only** in this app. On Linux the
  connect screen offers TCP only (a WiFi/Ethernet companion or a local
  simulator); the BLE transport stays mobile. The `flutter_blue_plus` plugin
  does have a Linux binding, but BLE on desktop via BlueZ is not validated —
  treat it as future work, not a supported path.
- **File import/export** (field packs) is Android/iOS only; the library
  itself (list/delete) is fully usable on Linux.
- **No foreground service** on Linux — the transfer runs in-process, so keep
  the window open during an update. (On Android/iOS the transfer keeps its
  foreground service.)
- The Linux build is not signed, versioned, or shipped — APKs remain the
  release artifact. CI builds it on every push to keep it honest.

Releases are built and signed by CI — see
[docs/releasing.md](docs/releasing.md). Sideload note: installs from GitHub
Releases are signed with the app signing key, so replacing an install keeps
your data.

## Layout

```text
app/                     the Flutter app (screens, services, theme)
packages/mesh_protocol/  subtree from MeshChameleon — wire codec, crypto (MIT)
packages/device_link/    subtree from MeshChameleon — RadioLink SPI, TCP link (MIT)
packages/test_support/   subtree from MeshChameleon — test plumbing (MIT)
packages/companion_client/  companion-protocol client (contacts, login, remote CLI)
packages/ota_core/       wire format, `ota status` contract, delta engine,
                         transfer engine (windowed, OP_ASK/OP_REPORT)
```

The `mesh_protocol`/`device_link`/`test_support` packages are reused from
[MeshChameleon](https://github.com/jhuebert/MeshChameleon) via `git subtree`
(history preserved). See [ATTRIBUTION.md](ATTRIBUTION.md).

## The OTA wire contract

The app and the fork's repeater firmware (`meshcore/MeshCore`, branch
`lora-ota`, `examples/simple_repeater/OtaUpdate.h`) speak a frozen,
append-only contract. Its shape, in one line:

`CMD_SEND_BINARY_REQ` → companion encrypts → ordinary REQ datagram → node
decrypts → `OTA` op frame → reply inside the RESPONSE as
`PUSH_CODE_BINARY_RESPONSE` → only the target applies anything.

- Ops are inert until an operator arms with `ota stage` + a single-use token;
  nothing reaches flash before the SHA-256 gate at `OP_END` passes.
- `OP_INFO` (0x07) is the capability handshake, answered in every state; the
  node replies with `OP_INFO_REPORT` (0x08): wire version, target id, slot
  size, `max_literal`, feature bits (`supportsDelta`, `supportsApply`), the
  running firmware version and the **full running-slot SHA-256**.
- New features only ever add op codes or report bits; op meaning, field order,
  field sizes, CRC and the SEQ rules are frozen. Any hard break is a new REQ
  code, never a silent redefinition.
- The frame CRC (CRC-16/CCITT-FALSE) guards flash writes, not the transport
  (the AES-MAC does); packets carry zero padding from the crypto layer and
  `frame_len` in the REQ envelope says exactly how much of it is the frame.

`bench/` is the hardware front door for the same contract: `dart run
bin/bench.dart --scenario probe|delta|full|…` drives the real path end to end.

## Contributing

Small, focused PRs against `main`. `./scripts/check.sh` must stay green
(format, analyze, all package tests, app tests). The `mesh_protocol`,
`device_link`, and `test_support` trees are shared with MeshChameleon —
prefer upstreaming shared fixes there via the subtree rather than diverging.

## License

MIT — see [LICENSE](LICENSE) and [ATTRIBUTION.md](ATTRIBUTION.md).
