#!/usr/bin/env bash
# Regenerate the screenshots embedded in the user guide (README.md) on an
# attached device. Runs an integration test (real fonts) rather than a golden
# test (placeholder text), writing 860x1864 PNGs into docs/images.
#
# Usage: scripts/screenshots.sh [--device ID] [--out DIR] [--check]
set -euo pipefail
cd "$(dirname "$0")/.."

FLUTTER="${FLUTTER:-flutter}"
DEVICE="${SCREENSHOT_DEVICE:-linux}"
OUT="${SCREENSHOT_DIR:-docs/images}"
CHECK=0

usage() {
  cat <<EOF
usage: $0 [--device ID] [--out DIR] [--check]

  --device ID  flutter device to capture on (default: $DEVICE)
  --out DIR    where to write the PNGs (default: $OUT)
  --check      only verify that every screenshot referenced by README.md exists
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      DEVICE="$2"; shift 2 ;;
    --out)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      OUT="$2"; shift 2 ;;
    --check)
      CHECK=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# The guide's embeds are the contract: every one of them must have a file.
mapfile -t referenced < <(grep -oE 'docs/images/[A-Za-z0-9._-]+\.png' README.md | sort -u)
if [[ ${#referenced[@]} -eq 0 ]]; then
  echo "no docs/images/*.png embeds found in README.md" >&2
  exit 1
fi

if [[ $CHECK -eq 1 ]]; then
  missing=0
  for img in "${referenced[@]}"; do
    if [[ -s "$OUT/$(basename "$img")" ]]; then
      echo "ok       $img"
    else
      echo "MISSING  $img"
      missing=1
    fi
  done
  exit "$missing"
fi

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

echo "== capturing ${#referenced[@]} guide screenshots on $DEVICE -> $OUT_ABS =="
(
  cd app
  "$FLUTTER" test integration_test/guide_screenshots_test.dart \
    -d "$DEVICE" \
    --dart-define=SCREENSHOT_DIR="$OUT_ABS"
)

echo "== verifying guide embeds =="
missing=0
for img in "${referenced[@]}"; do
  if [[ -s "$OUT/$(basename "$img")" ]]; then
    echo "ok       $img"
  else
    echo "MISSING  $img"
    missing=1
  fi
done
exit "$missing"
