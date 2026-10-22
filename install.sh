#!/bin/sh
# Установка apkg НА станции (Android или buildroot).
#   curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
set -e

APKG_URL="${APKG_URL:-https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg}"

is_android() {
  [ -e /system/bin/linker64 ] || [ -e /system/bin/linker ]
}

pick_curl() {
  for c in curl /data/local/bin/curl /usr/local/bin/curl /usr/bin/curl /bin/curl; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# buildroot: сразу rw, иначе Read-only file system
if ! is_android; then
  mount -o remount,rw / 2>/dev/null || true
  mount -o remount,rw /usr 2>/dev/null || true
  mount -o remount,rw /opt 2>/dev/null || true
fi

if is_android; then
  BINDIR="${APKG_BINDIR:-/data/local/bin}"
  TMP="${APKG_TMP:-/data/local/tmp}"
  echo "→ Android · $BINDIR"
else
  BINDIR="${APKG_BINDIR:-/usr/local/bin}"
  TMP="${APKG_TMP:-/tmp}"
  mkdir -p "$BINDIR" 2>/dev/null || BINDIR="${APKG_BINDIR:-/opt/bin}"
  echo "→ buildroot · $BINDIR"
fi

mkdir -p "$BINDIR" "$TMP"
STAGE="$TMP/apkg.$$"
C=$(pick_curl) || { echo "нет curl — scripts/install-adb.sh" >&2; exit 1; }
"$C" -kfsSL -o "$STAGE" "$APKG_URL"
chmod 755 "$STAGE"
mv -f "$STAGE" "$BINDIR/apkg"
export PATH="$BINDIR:$PATH"

echo "✓ apkg → $BINDIR/apkg"
"$BINDIR/apkg" paths
"$BINDIR/apkg" update
echo "Дальше: apkg install nano curl"
