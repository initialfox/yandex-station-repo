#!/bin/sh
# Залить dist/*.tar (+ apkg) на orphan-ветку pkg → raw.githubusercontent.com
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
test -d "$DIST" || { echo "нет $DIST — сначала pack-packages.sh"; exit 1; }

TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill 2>/dev/null | awk -F= '/^password=/{print $2}')
ORIGIN=$(git -C "$ROOT" remote get-url origin)
case "$ORIGIN" in
  https://*)
    if [ -n "$TOKEN" ]; then
      ORIGIN="https://x-access-token:${TOKEN}@github.com/$(echo "$ORIGIN" | sed -E 's#https://([^/]+@)?github.com/##')"
    fi
    ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp "$DIST"/*.tar "$TMP/" 2>/dev/null || true
rm -f "$TMP/apkg.tar"
test -f "$DIST/apkg" && cp "$DIST/apkg" "$TMP/apkg"
cp "$ROOT/packages.json" "$TMP/packages.json"
# тяжёлые опционально: SKIP_HEAVY=1
if [ "${SKIP_HEAVY:-}" = 1 ]; then
  rm -f "$TMP/ffmpeg.tar" "$TMP/nmap.tar"
fi

cd "$TMP"
git init -q -b pkg
git config http.postBuffer 524288000
git config http.version HTTP/1.1
git add -A
git -c user.email="apkg@local" -c user.name="apkg" commit -q -m "packages: refresh $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git remote add origin "$ORIGIN"
git push -f origin pkg
echo "✓ pkg → https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/"
