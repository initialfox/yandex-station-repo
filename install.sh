#!/bin/sh
# Установка apkg НА станции (Android или buildroot).
#   curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
# На колонках DNS часто ::1:53 — резолвим через 8.8.8.8 / 77.88.8.8 и curl --resolve.
set -e

APKG_URL="${APKG_URL:-https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg}"

is_android() {
  [ -e /system/bin/linker64 ] || [ -e /system/bin/linker ]
}

# заглушить шум Go/bionic про tzdata
if is_android; then
  export ANDROID_DATA="${ANDROID_DATA:-/data}"
  export ANDROID_ROOT="${ANDROID_ROOT:-/system}"
fi

pick_curl() {
  for c in curl /data/local/bin/curl /usr/local/bin/curl /usr/bin/curl /bin/curl; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# A-запись через публичный DNS (обход битого resolv.conf)
resolve_ip() {
  host="$1"
  dns_list="8.8.8.8 77.88.8.8 1.1.1.1"
  for dns in $dns_list; do
    # busybox/toybox nslookup
    out=$(nslookup "$host" "$dns" 2>/dev/null) || out=$(busybox nslookup "$host" "$dns" 2>/dev/null) || out=""
    ip=$(printf '%s\n' "$out" | awk '/^Address/ {print $NF}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | tail -1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
    # dig
    ip=$(dig +short @"$dns" "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    if [ -n "$ip" ]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

curl_get() {
  # $1=url $2=dest
  url="$1"
  dest="$2"
  C=$(pick_curl) || { echo "нет curl" >&2; return 1; }

  host=$(printf '%s' "$url" | sed -E 's#^https?://([^/]+)/.*#\1#')
  # сначала обычный
  if "$C" -kfsSL --connect-timeout 15 -o "$dest" "$url" 2>/dev/null; then
    return 0
  fi
  echo "→ DNS битый, пробую --resolve ($host)…"
  ip=$(resolve_ip "$host") || true
  if [ -z "$ip" ]; then
    # запасные IP иногда помогают для raw.githubusercontent.com / github
    case "$host" in
      raw.githubusercontent.com)
        for ip in 185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133; do
          if "$C" -kfsSL --connect-timeout 15 --resolve "$host:443:$ip" -o "$dest" "$url"; then
            return 0
          fi
        done
        ;;
      github.com)
        for ip in 140.82.121.4 140.82.121.3; do
          if "$C" -kfsSL --connect-timeout 15 --resolve "$host:443:$ip" -o "$dest" "$url"; then
            return 0
          fi
        done
        ;;
    esac
    echo "не удалось скачать: $url" >&2
    return 1
  fi
  "$C" -kfsSL --connect-timeout 20 --resolve "$host:443:$ip" --resolve "$host:80:$ip" -o "$dest" "$url"
}

if ! is_android; then
  mount -o remount,rw / 2>/dev/null || true
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
curl_get "$APKG_URL" "$STAGE"
chmod 755 "$STAGE"
mv -f "$STAGE" "$BINDIR/apkg"
export PATH="$BINDIR:$PATH"
export ANDROID_DATA="${ANDROID_DATA:-/data}"
export ANDROID_ROOT="${ANDROID_ROOT:-/system}"

echo "✓ apkg → $BINDIR/apkg"
"$BINDIR/apkg" version 2>/dev/null || true
"$BINDIR/apkg" paths
"$BINDIR/apkg" update
echo "Дальше: apkg install nano curl"
