#!/usr/bin/env bash
# Regression checks for scripts/build_metadata.sh, including BSD date (macOS).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
expected='--dart-define=MESHCORE_REPEATER_MANAGER_BUILD_TIME=1970-01-01T00:00:00Z'

read_meta() {
  MESHCORE_REPEATER_MANAGER_GIT_COMMIT=test MESHCORE_REPEATER_MANAGER_GIT_DIRTY=0 \
    SOURCE_DATE_EPOCH=0 \
    bash -c 'source "$1/scripts/build_metadata.sh" >/dev/null 2>&1; printf "%s\n" "${metadata_args[@]}"' \
    _ "$root"
}

meta="$(read_meta)"
[[ "$meta" == *"$expected"* ]] ||
  { echo "build metadata: wrong timestamp: $meta" >&2; exit 1; }

if ! date -u -d "@0" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  echo "build metadata: BSD date host, both paths exercised"
  exit 0
fi

# GNU host: shim date so -d fails the way it does on macOS, while -r works.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_date="$(command -v date)"
cat > "$tmp/date" <<EOF
#!/usr/bin/env bash
set -euo pipefail
epoch=""
fmt=""
while ((\$#)); do
  case "\$1" in
    -u) shift ;;
    -d) echo "date: illegal option -- d" >&2; exit 1 ;;
    -r) epoch="\$2"; shift 2 ;;
    +*) fmt="\$1"; shift ;;
    *) shift ;;
  esac
done
"$real_date" -u -d "@\${epoch}" "\$fmt"
EOF
chmod +x "$tmp/date"

meta="$(PATH="$tmp:$PATH" read_meta)"
[[ "$meta" == *"$expected"* ]] ||
  { echo "build metadata: BSD date path failed: $meta" >&2; exit 1; }

echo "build metadata: GNU and BSD date paths agree"
