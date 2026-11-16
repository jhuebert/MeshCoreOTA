# MeshCoreOTA — Agent Guide

Over-the-air firmware updates for MeshCore repeaters: a Flutter app (Android,
and a Linux desktop *testing* build) plus a hardware bench harness
(`bench/`). Companion firmware changes live in the `lora-ota` branch of the
fork at `jhuebert/MeshCore` (`examples/simple_repeater/OtaUpdate.*`); the app
and the fork are two halves of one feature and must stay in sync.

## Layout

- `app/` — Flutter app (screens, services, theme).
- `packages/ota_core/` — wire contract (op frames, CRC), the frozen `ota
  status` CLI-line parser, the delta engine (rolling-hash matcher), the
  windowed transfer engine (REQ/RESPONSE, op retry from `next_expected`).
- `packages/mesh_protocol/` — codec, crypto, models (fork of the MeshChameleon
  `mesh_protocol`; subtree-imported).
- `packages/device_link/` — TCP/BLE/fake transport, `RadioLink`, binary
  requests.
- `packages/companion_client/` — contacts, login, `remoteCli`, message pump.
- `bench/` — hardware harness (never run in CI): `--scenario probe|measure|full|delta|reject|cancel|...`.

## Gates (all must pass before pushing)

```sh
./scripts/check.sh     # format, analyze, all tests (plus app tests)
./scripts/coverage.sh  # runs the same tests with coverage; coverage_baseline.json is the gate
```

CI (`.github/workflows/ci.yml`) runs both. The `mesh_protocol`/`device_link`/
`test_support` trees are shared with MeshChameleon — prefer fixing bugs
upstream there (via subtree) rather than diverging.

## The OTA wire contract — stability rules

`packages/ota_core/lib/src/wire.dart` mirrors `examples/simple_repeater/OtaUpdate.h`; `OtaUpdate.h` is the authoritative spec.

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
  hardware id. Flashing a node with another variant of the same board (e.g.
  `_observer` ↔ plain) is refused by the node and by `stage()` — switch
  variants over USB/Wi-Fi, not OTA.
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

## Bench/live-mesh coupling

- The bench drives real radios through TCP companions; zero-hop and
  multi-hop (`--path`) are both supported.
- When running against the live mesh, keep traffic minimal: read-only
  `probe`, one-byte stage/abort cycles, and DIRECT paths when possible.
  Restore the companion's contact path to zero-hop when done.
- Live-mesh tests leak into the fork's hardware — a failed flash is
  recoverable via `ota rollback` on-device, but leave the node idle and
  on its last-good image when finished.

## Commit discipline

- Work on `main` here (this repo is mine). Commit format/analyze/test-green
  only. One concern per commit.
- The fork (`MeshCore/examples/simple_repeater/OtaUpdate.*`) is a
  PRIME-time fork: keep fork changes minimal, and always run the native
  tests (`pio test -e native_ota`) and the app gates together.
- Tags `x.y.z` cut releases (see `docs/releasing.md`); `CHANGELOG.md` carries
  every user-visible behavior.
