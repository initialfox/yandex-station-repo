#!/usr/bin/env bash
# Собрать Alpine musl-бандл для aarch64: openvpn, wireguard, darkhttpd, sqlite, python3
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64}"
WORK="$ROOT/.build/alpine"
rm -rf "$WORK"
mkdir -p "$WORK/apks" "$WORK/root"

fetch() {
  local name="$1"
  local url
  url=$(curl -fsSL "$MIRROR/" | grep -oE "href=\"${name}-[0-9][^\"]+\.apk\"" | head -1 | sed 's/href="//;s/"$//')
  if [ -z "$url" ]; then
    echo "not found: $name" >&2
    return 1
  fi
  echo "GET $url"
  curl -fsSL -o "$WORK/apks/$url" "$MIRROR/$url"
}

extract_apk() {
  local apk="$1"
  local dir="$WORK/extract/$(basename "$apk" .apk)"
  rm -rf "$dir"
  mkdir -p "$dir"
  # apk = gzip tar
  tar -xzf "$apk" -C "$dir" 2>/dev/null || {
    # some are just tar
    tar -xf "$apk" -C "$dir"
  }
  # copy usr/bin lib etc into root
  cp -a "$dir"/. "$WORK/root/" 2>/dev/null || true
  if [ -d "$dir/usr" ]; then cp -a "$dir/usr"/. "$WORK/root/usr/" 2>/dev/null || mkdir -p "$WORK/root/usr" && cp -a "$dir/usr"/. "$WORK/root/usr/"; fi
  if [ -d "$dir/lib" ]; then mkdir -p "$WORK/root/lib" && cp -a "$dir/lib"/. "$WORK/root/lib/"; fi
}

bundle() {
  local name="$1"
  shift
  local pkgs=("$@")
  echo "==> bundle $name (${pkgs[*]})"
  rm -rf "$WORK/root"
  mkdir -p "$WORK/root/usr/bin" "$WORK/root/lib" "$WORK/root/usr/lib" "$WORK/root/usr/share"
  for p in "${pkgs[@]}"; do
    fetch "$p" || true
  done
  for apk in "$WORK/apks"/*.apk; do
    [ -f "$apk" ] || continue
    case "$(basename "$apk")" in
      ${name}*|musl*|lib*|sqlite*|python*|ncurses*|readline*|xz*|expat*|gdbm*|mpdecimal*|openssl*|libcrypto*|libssl*|libffi*|lzo*|lz4*|libcap*|darkhttpd*|openvpn*|wireguard*|zlib*)
        extract_apk "$apk" || true
        ;;
    esac
  done
  # always pull musl loader
  fetch musl || true
  for apk in "$WORK/apks"/musl-*.apk; do
    [ -f "$apk" ] && extract_apk "$apk" || true
  done

  OUT="$ROOT/packages/$name"
  rm -rf "$OUT"
  mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/share"

  # find musl loader
  LOADER=$(find "$WORK/root" -name 'ld-musl-aarch64.so.1' | head -1)
  if [ -n "$LOADER" ]; then
    cp -a "$LOADER" "$OUT/lib/"
    # libc
    find "$WORK/root" -name 'libc.musl-aarch64.so.1' -exec cp -a {} "$OUT/lib/" \;
    ln -sfn ld-musl-aarch64.so.1 "$OUT/lib/libc.so" 2>/dev/null || true
  fi

  # copy libs
  find "$WORK/root" -type f \( -name '*.so*' \) ! -path '*/ld-musl*' 2>/dev/null | while read -r f; do
    cp -a "$f" "$OUT/lib/" 2>/dev/null || true
  done

  case "$name" in
    openvpn)
      find "$WORK/root" -type f -name openvpn | head -1 | while read -r f; do cp -a "$f" "$OUT/bin/openvpn"; done
      cat > "$OUT/openvpn-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/openvpn
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/openvpn" "$@"
EOF
      chmod +x "$OUT/openvpn-run" "$OUT/bin/openvpn"
      ;;
    wireguard)
      find "$WORK/root" -type f \( -name wg -o -name wg-quick \) | while read -r f; do
        cp -a "$f" "$OUT/bin/$(basename "$f")"
      done
      # wireguard-go userspace (built separately if present)
      if [ -x "$ROOT/.build/wireguard-go" ]; then
        cp -a "$ROOT/.build/wireguard-go" "$OUT/bin/wireguard-go"
      fi
      cat > "$OUT/wireguard-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/wireguard
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
export PATH="$DIR/bin:$PATH"
BIN="${1:-wg}"
shift 2>/dev/null || true
case "$BIN" in
  wg|wg-quick|wireguard-go) ;;
  *) set -- "$BIN" "$@"; BIN=wg ;;
esac
if [ "$BIN" = "wireguard-go" ] || [ ! -f "$DIR/lib/ld-musl-aarch64.so.1" ]; then
  exec "$DIR/bin/$BIN" "$@"
fi
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/$BIN" "$@"
EOF
      # simpler wrappers
      cat > "$OUT/wg-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/wireguard
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
export PATH="$DIR/bin:$PATH"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/wg" "$@"
EOF
      cp "$OUT/wg-run" "$OUT/wireguard-run"
      chmod +x "$OUT"/*-run "$OUT/bin/"* 2>/dev/null || true
      ;;
    darkhttpd)
      find "$WORK/root" -type f -name darkhttpd | head -1 | while read -r f; do cp -a "$f" "$OUT/bin/darkhttpd"; done
      cat > "$OUT/darkhttpd-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/darkhttpd
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/darkhttpd" "$@"
EOF
      chmod +x "$OUT/darkhttpd-run" "$OUT/bin/darkhttpd"
      ;;
    sqlite)
      find "$WORK/root" -type f -name sqlite3 | head -1 | while read -r f; do cp -a "$f" "$OUT/bin/sqlite3"; done
      cat > "$OUT/sqlite-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/sqlite
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/sqlite3" "$@"
EOF
      chmod +x "$OUT/sqlite-run" "$OUT/bin/sqlite3"
      ;;
    python3)
      # copy full tree
      mkdir -p "$OUT/usr"
      cp -a "$WORK/root/usr/bin/python3"* "$OUT/bin/" 2>/dev/null || true
      cp -a "$WORK/root/usr/lib/python3"* "$OUT/" 2>/dev/null || true
      # also libs already in lib/
      ln -sfn python3.12 "$OUT/bin/python3" 2>/dev/null || ln -sfn python3 "$OUT/bin/python3"
      cat > "$OUT/python3-run" <<'EOF'
#!/system/bin/sh
DIR=/data/local/opt/python3
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH}"
export PYTHONHOME="$DIR"
# stdlib may live in DIR/python3.12
if [ -d "$DIR/python3.12" ]; then
  export PYTHONPATH="$DIR/python3.12:${PYTHONPATH:-}"
fi
PY="$DIR/bin/python3"
[ -x "$PY" ] || PY="$DIR/bin/python3.12"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$PY" "$@"
EOF
      chmod +x "$OUT/python3-run" "$OUT/bin/"* 2>/dev/null || true
      ;;
  esac
  echo "built $OUT ($(du -sh "$OUT" | awk '{print $1}'))"
}

# clear apk cache between bundles for cleaner deps — or accumulate
rm -rf "$WORK/apks"
mkdir -p "$WORK/apks"

bundle openvpn openvpn lzo lz4-libs libcap-ng openssl libcrypto3 libssl3 zlib
rm -rf "$WORK/apks"; mkdir -p "$WORK/apks"
bundle wireguard wireguard-tools-wg wireguard-tools-wg-quick
rm -rf "$WORK/apks"; mkdir -p "$WORK/apks"
bundle darkhttpd darkhttpd
rm -rf "$WORK/apks"; mkdir -p "$WORK/apks"
bundle sqlite sqlite sqlite-libs readline ncurses-libs
rm -rf "$WORK/apks"; mkdir -p "$WORK/apks"
bundle python3 python3 python3-pyc libffi expat mpdecimal readline ncurses-libs xz-libs gdbm openssl libcrypto3 libssl3 zlib sqlite-libs

echo DONE
