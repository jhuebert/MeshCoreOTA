# MeshCoreOTA

Over-the-air firmware updater for **MeshCore repeaters** — from your phone,
over LoRa, with no laptop at the tower and no mesh flood traffic.

The app talks to a stock MeshCore companion device over BLE (Nordic UART
Service) or TCP, and uses it purely as a raw radio. It sends DIRECT-routed
`PAYLOAD_TYPE_RAW_CUSTOM` packets carrying a tiny op protocol to the repeater:
the app picks the board, the version and the transfer parameters; the repeater
only applies ops and verifies SHA-256. Everything else is app-side.

Status: **field-bench milestone** — not yet validated against hardware. Android
only; iOS unsupported. There is deliberately no companion-firmware change: the
companion is used exactly as it ships.

For the design see the fork plan documents in
[jhuebert/MeshCore](https://github.com/jhuebert/MeshCore) (`docs` / `plans`).

## How it works

1. Connect to a companion (BLE or TCP). 2. Pick a repeater from the companion's
   contacts (or enter a pubkey). 3. Pick a firmware (GitHub release, or the
   offline library — verified end-to-end by SHA-256). 4. Review. 5. Transfer —
   a delta against the running image is the default; full image is the
   fallback. 6. The app triggers `ota apply` and verifies the new firmware
   after reboot. A broken image flips back automatically in the companion
   firmware (fork `lora-ota` branch).

## Building

Flutter stable (CI uses the pinned version in
[.github/workflows/ci.yml](.github/workflows/ci.yml)). From the repo root:

```sh
./scripts/check.sh     # analyze + test all packages and the app
```

Release artifacts are built by CI on GitHub (see
[docs/releasing.md](docs/releasing.md)); Debug/release APKs can be built locally
with the Flutter Android toolchain once the Android SDK is configured.

## Scope

- Android only. Android-sideloaded APKs published as GitHub Releases.
- `PAYLOAD_TYPE_RAW_CUSTOM` DIRECT packets only; no flood, ever.
- Desktop is not supported. No iOS. No F-Droid/Play requirement.

## License

MIT — see [LICENSE](LICENSE) and [ATTRIBUTION.md](ATTRIBUTION.md).
