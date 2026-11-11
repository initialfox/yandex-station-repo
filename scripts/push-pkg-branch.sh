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
# Голый бинарь apkg качают install*.sh. pack-packages.sh его не собирает, и без
# dist/apkg force-push удалил бы его из pkg — тогда берём уже опубликованный.
if [ -f "$DIST/apkg" ]; then
  cp "$DIST/apkg" "$TMP/apkg"
elif curl -fsSL -o "$TMP/apkg" "https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg" ||
  git -C "$ROOT" cat-file blob origin/pkg:apkg > "$TMP/apkg" 2>/dev/null; then
  echo "dist/apkg нет — оставляю опубликованный apkg из ветки pkg"
else
  echo "нет dist/apkg и не удалось взять текущий apkg из ветки pkg — без него install.sh сломается"
  exit 1
fi
cp "$ROOT/packages.json" "$TMP/packages.json"
# тяжёлые опционально: SKIP_HEAVY=1
if [ "${SKIP_HEAVY:-}" = 1 ]; then
  rm -f "$TMP/ffmpeg.tar" "$TMP/nmap.tar"
fi
# ветка pkg перезаписывается целиком: всё, что индекс обещает, но сюда не попало, пропадёт
MISSING=$(python3 - "$ROOT/packages.json" "$TMP" <<'PY'
import json, os, sys
for p in json.load(open(sys.argv[1], encoding="utf-8"))["packages"]:
    asset = p.get("asset") or p["name"] + ".tar"
    if not os.path.exists(os.path.join(sys.argv[2], asset)):
        print("  %s (%s)" % (p["name"], asset))
PY
)
if [ -n "$MISSING" ]; then
  echo "ВНИМАНИЕ: в индексе есть, но в ветку pkg не попадут (apkg install даст 404):"
  echo "$MISSING"
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
