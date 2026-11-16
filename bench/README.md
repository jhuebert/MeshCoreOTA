# bench — hardware bench harness

Drives the LoRa OTA path against real radios. Not part of the app or the test
suites: it needs two radios on a desk, so it is never run in CI.

```sh
cd bench
dart pub get

# read-only health check through a TCP companion (also prints OP_INFO)
dart run bin/bench.dart --host 192.168.1.165 --password password \
  --contact XiaoS3 --env Xiao_S3_WIO_repeater_observer --scenario probe

# just the OP_INFO negotiation handshake
dart run bin/bench.dart ... --scenario probe

# full-image update, then commit and verify after reboot
dart run bin/bench.dart ... --image new.bin --scenario full

# base-matched delta (the normal case: --base is the image the node runs)
dart run bin/bench.dart ... --image new.bin --base running.bin --scenario delta

# timing only: stage and transfer, never apply
dart run bin/bench.dart ... --image big.bin --base running.bin --scenario measure

# route over an explicit DIRECT path instead of the saved/zero-hop route
# (pushes the path into the companion's contact record, like change_path)
dart run bin/bench.dart ... --image new.bin --base running.bin \
  --path c0ff,c0c0 --scenario probe

# failure modes: bad token, corrupted literal stream, mid-transfer abort
dart run bin/bench.dart ... --image new.bin --scenario reject

# resume a full-image stage after the bench process was interrupted
# --image must be the exact image already staged on the node
dart run bin/bench.dart ... --image staged.bin --scenario resume

# wrong target and expired arm (expiry waits 125 s)
dart run bin/bench.dart ... --image new.bin --scenario wrongtarget
dart run bin/bench.dart ... --image new.bin --scenario expiry

# cancel a partial transfer, abort, and confirm a fresh arm works
dart run bin/bench.dart ... --image new.bin --scenario cancel

# partition flip back after an applied update
dart run bin/bench.dart ... --scenario rollback
```

`--env` **must** be the PlatformIO environment the node's firmware was built
for: the wire `target_id` is `sha256(env)[0..3]`, and the node refuses an arm
meant for another board.

Useful flags: `--window N` (ops per ask; default 4), `--spacing MS` (delay
between queued writes; default is airtime-derived from the companion's radio
config, matching the app — pass an explicit value to override), `--port`,
`--contact`.

`bin/probe.dart` and `bin/probe2.dart` are single-shot wire probes used to
localise a fault: they arm a session, send one `OP_START` inside a binary
request (and in `probe2` one op and one `OP_ASK`), and dump every packet the
companion reports as received.
That is how the arm-token byte order and the duplicate-filter bugs were found —
a transfer that stalls tells you nothing, whereas "the node saw `OP_START` but
no `OP_REPORT` ever came back" pins it immediately.

## What the numbers mean

The harness prints wall-clock time, packets, retries and literal bytes. At
SF7 / BW500 / CR4-5 a maximum-size op frame is ~70 ms of airtime, so a
full-image transfer is dominated by packet count — which is exactly why the
delta path exists. A base-matched delta of a small change is seconds; a
structural change (anything that shifts the vtable or a shared table) can
approach the full-image cost, because the delta engine can only reuse runs of
bytes that did not move.

The companion's duty cycle matters as much as the radio settings: with
`airtime_factor = 0` it transmits at 100 %, and a nonzero factor divides the
achievable rate accordingly.
