#!/usr/bin/env bash
# Regenerate every icon asset from the authoritative SVG source:
#   1. app/assets/icon/icon.png (Flutter asset and the README logo)
#   2. Android launcher + adaptive icons, macOS app iconset, Windows .ico,
#      via flutter_launcher_icons (configured in app/pubspec.yaml).
#
# Usage: scripts/icons.sh [--check]
#   --check  only verify that every expected icon is present; write nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

DART="${DART:-dart}"
RSVG="${RSVG:-rsvg-convert}"
SVG="app/assets/icon/icon.svg"
PNG="app/assets/icon/icon.png"
CHECK=0

usage() {
  cat <<EOF
usage: $0 [--check]

  --check  verify the icon source and every generated target exist (no writes)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
  esac
done

# flutter_launcher_icons config in app/pubspec.yaml generates these. Keep the
# list in sync with that config (or the --check gate will catch a missing one).
targets=(
  "$SVG"
  "$PNG"
  app/android/app/src/main/res/values/colors.xml
  app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml
  app/windows/runner/resources/app_icon.ico
  app/macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json
)
for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
  targets+=(
    "app/android/app/src/main/res/mipmap-$density/ic_launcher.png"
    "app/android/app/src/main/res/drawable-$density/ic_launcher_foreground.png"
  )
done
for size in 16 32 64 128 256 512 1024; do
  targets+=("app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png")
done

check_targets() {
  local missing=0 target
  for target in "${targets[@]}"; do
    if [[ -s "$target" ]]; then
      echo "ok       $target"
    else
      echo "MISSING  $target"
      missing=1
    fi
  done
  return "$missing"
}

if [[ $CHECK -eq 1 ]]; then
  check_targets
  exit $?
fi

if [[ ! -f "$SVG" ]]; then
  echo "icon source missing: $SVG" >&2
  exit 1
fi

echo "== render $PNG from $SVG =="
if command -v "$RSVG" >/dev/null 2>&1; then
  "$RSVG" -w 1024 -h 1024 -o "$PNG" "$SVG"
elif command -v magick >/dev/null 2>&1; then
  # ImageMagick's SVG delegate is less faithful than librsvg, but works when
  # rsvg-convert is not installed.
  magick -background none "$SVG" -resize 1024x1024 "$PNG"
else
  echo "need rsvg-convert (preferred) or ImageMagick to render the icon" >&2
  exit 1
fi
if ! file "$PNG" | grep -q '1024 x 1024'; then
  echo "$PNG is not 1024x1024" >&2
  exit 1
fi

echo "== generate platform icons =="
(
  cd app
  "$DART" run flutter_launcher_icons
)

echo "== verify icon targets =="
check_targets
