#!/bin/sh
# Установка apkg НА станции (Android или buildroot).
# SSH:  curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
# ADB:  см. scripts/install-adb.sh с компа
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

download() {
  dest="$1"
  if C=$(pick_curl); then
    "$C" -kfsSL -o "$dest" "$APKG_URL"
    return
  fi
  echo "нет curl — используй scripts/install-adb.sh (push с компа)" >&2
  exit 1
}

if is_android; then
  BINDIR="${APKG_BINDIR:-/data/local/bin}"
  TMP="${APKG_TMP:-/data/local/tmp}"
  echo "→ Android · bindir $BINDIR"
else
  BINDIR="${APKG_BINDIR:-/usr/local/bin}"
  TMP="${APKG_TMP:-/tmp}"
  if ! mkdir -p "$BINDIR" 2>/dev/null; then
    BINDIR="${APKG_BINDIR:-/opt/bin}"
  fi
  echo "→ buildroot · bindir $BINDIR"
fi

mkdir -p "$BINDIR" "$TMP"
STAGE="$TMP/apkg.$$"
download "$STAGE"
chmod 755 "$STAGE"
mv -f "$STAGE" "$BINDIR/apkg"
export PATH="$BINDIR:$PATH"

echo "✓ apkg → $BINDIR/apkg"
"$BINDIR/apkg" paths
"$BINDIR/apkg" update
echo
echo "Дальше: apkg list · apkg install nano curl"
