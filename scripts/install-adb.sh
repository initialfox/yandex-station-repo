#!/bin/sh
# С компа: скачать apkg и залить на станцию через adb push.
#   ./scripts/install-adb.sh
#   ./scripts/install-adb.sh -s SERIAL
#   ANDROID=1 ./scripts/install-adb.sh
#   BUILDROOT=1 ./scripts/install-adb.sh
set -e

APKG_URL="${APKG_URL:-https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg}"
ADB="${ADB:-adb}"
SERIAL=""

while [ $# -gt 0 ]; do
  case "$1" in
    -s|--serial) SERIAL="$2"; shift 2 ;;
    -h|--help) echo "Usage: $0 [-s serial]"; exit 0 ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

adb_cmd() {
  if [ -n "$SERIAL" ]; then
    "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" "$@"
  fi
}

echo "→ devices"
adb_cmd devices

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
echo "↓ $APKG_URL"
curl -fsSL -o "$TMP" "$APKG_URL"
chmod 755 "$TMP"
echo "  $(wc -c < "$TMP" | tr -d ' ') bytes"

FLAVOR=$(adb_cmd shell 'if [ -e /system/bin/linker64 ] || [ -e /system/bin/linker ]; then echo android; else echo buildroot; fi' | tr -d '\r\n')
[ -n "${ANDROID:-}" ] && FLAVOR=android
[ -n "${BUILDROOT:-}" ] && FLAVOR=buildroot

if [ "$FLAVOR" = android ]; then
  BINDIR="/data/local/bin"
  DEVTMP="/data/local/tmp"
else
  BINDIR="/usr/local/bin"
  DEVTMP="/tmp"
fi

echo "→ flavor $FLAVOR · push → $DEVTMP/apkg → $BINDIR/apkg"

if [ "$FLAVOR" = buildroot ]; then
  echo "→ remount rw (rootfs часто read-only)"
  adb_cmd shell 'mount -o remount,rw /; mount -o remount,rw /usr; mount -o remount,rw /usr/local; mount -o remount,rw /opt; mount -o remount,rw /bkupgrade' 2>/dev/null || true
fi

adb_cmd shell "mkdir -p $DEVTMP $BINDIR" 2>/dev/null || true
adb_cmd push "$TMP" "$DEVTMP/apkg"

REMOTE="mkdir -p $BINDIR; cp $DEVTMP/apkg $BINDIR/apkg; chmod 755 $BINDIR/apkg; export PATH=$BINDIR:\$PATH; apkg paths; apkg update"

if [ "$FLAVOR" = android ]; then
  adb_cmd shell su 0 sh -c "$REMOTE"
else
  adb_cmd shell "sh -c '$REMOTE'"
fi

echo
echo "✓ готово. На станции: export PATH=$BINDIR:\$PATH && apkg install nano"
echo "  buildroot + read-only: mount -o remount,rw /   перед install"
