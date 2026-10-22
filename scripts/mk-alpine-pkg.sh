#!/usr/bin/env bash
# Собрать musl-бандл из Alpine aarch64 APK → packages/<name>/
# Usage: ./scripts/mk-alpine-pkg.sh <name> <apk> [apk...] [--bin binary] [--ver X] [--cat Y] [--desc Z]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${ALPINE_BRANCH:-v3.20}"
ARCH=aarch64
MIRRORS=(
  "https://dl-cdn.alpinelinux.org/alpine/${BRANCH}"
  "https://mirror.yandex.ru/mirrors/alpine/${BRANCH}"
)
WORK="$ROOT/.build/mk-$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/apks" "$WORK/root" "$WORK/idx"

NAME=""
APKS=()
BIN=""
VER=""
CAT="misc"
DESC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    --cat) CAT="$2"; shift 2 ;;
    --desc) DESC="$2"; shift 2 ;;
    --*) echo "unknown flag $1" >&2; exit 2 ;;
    *)
      if [[ -z "$NAME" ]]; then NAME="$1"; else APKS+=("$1"); fi
      shift
      ;;
  esac
done
[[ -n "$NAME" && ${#APKS[@]} -gt 0 ]] || { echo "usage: $0 name apk... [--bin b]"; exit 2; }
BIN="${BIN:-$NAME}"
DESC="${DESC:-$NAME}"

fetch_index() {
  local repo="$1" # main|community
  local out="$WORK/idx/${repo}.INDEX"
  [[ -f "$out" ]] && return 0
  local m
  for m in "${MIRRORS[@]}"; do
    if curl -fsSL "$m/${repo}/${ARCH}/APKINDEX.tar.gz" -o "$WORK/idx/${repo}.tgz"; then
      tar -xzf "$WORK/idx/${repo}.tgz" -C "$WORK/idx" APKINDEX 2>/dev/null || tar -xzf "$WORK/idx/${repo}.tgz" -C "$WORK/idx"
      mv "$WORK/idx/APKINDEX" "$out"
      echo "$m" > "$WORK/idx/${repo}.mirror"
      return 0
    fi
  done
  return 1
}

# parse APKINDEX → pkgs.tsv + so-providers.tsv
parse_index() {
  local idx="$1"
  python3 - "$idx" "$WORK/idx/pkgs.tsv" "$WORK/idx/so.tsv" <<'PY'
import sys
path, out_pkgs, out_so = sys.argv[1], sys.argv[2], sys.argv[3]
cur = {}
pkgs, so_map = [], {}

def strip_ver(d):
    return d.split('>')[0].split('<')[0].split('=')[0].split('~')[0]

def flush():
    if not cur.get('P'):
        return
    deps = []
    for d in (cur.get('D') or '').split():
        if d.startswith('cmd:'):
            continue
        if d.startswith('so:'):
            deps.append(d)  # keep so: for resolve
            continue
        name = strip_ver(d)
        if name and name not in deps:
            deps.append(name)
    pkgs.append('%s|%s|%s-%s.apk|%s' % (cur['P'], cur.get('V',''), cur['P'], cur.get('V',''), ' '.join(deps)))
    for p in (cur.get('p') or '').split():
        if p.startswith('so:'):
            so = p.split('=', 1)[0]  # so:libssl.so.3
            so_map.setdefault(so, cur['P'])

with open(path, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            flush(); cur = {}; continue
        if len(line) > 1 and line[1] == ':':
            cur[line[0]] = line[2:]
    flush()
open(out_pkgs, 'w').write('\n'.join(pkgs) + '\n')
open(out_so, 'w').write('\n'.join('%s|%s' % (k, v) for k, v in sorted(so_map.items())) + '\n')
PY
}

fetch_index main
fetch_index community || true
cat "$WORK/idx/main.INDEX" > "$WORK/idx/ALL.txt"
[[ -f "$WORK/idx/community.INDEX" ]] && cat "$WORK/idx/community.INDEX" >> "$WORK/idx/ALL.txt"
parse_index "$WORK/idx/ALL.txt"

resolve() {
  local wantf="$WORK/idx/want.txt"
  printf '%s\n' "${APKS[@]}" > "$wantf"
  python3 - "$WORK/idx/pkgs.tsv" "$WORK/idx/so.tsv" "$wantf" <<'PY'
import sys
from collections import deque
tsv, sof, wantf = sys.argv[1], sys.argv[2], sys.argv[3]
want = [l.strip() for l in open(wantf) if l.strip()]
db = {}
with open(tsv) as f:
    for line in f:
        parts = line.rstrip('\n').split('|', 3)
        if len(parts) < 4:
            continue
        p, v, fn, deps = parts
        db[p] = (v, fn, deps.split() if deps else [])
so_to_pkg = {}
with open(sof) as f:
    for line in f:
        if '|' not in line:
            continue
        so, pkg = line.rstrip('\n').split('|', 1)
        so_to_pkg[so] = pkg
need = deque(want)
seen = set()
order = []
while need:
    p = need.popleft()
    if p in seen:
        continue
    seen.add(p)
    if p.startswith('so:'):
        pkg = so_to_pkg.get(p)
        if pkg and pkg not in seen:
            need.append(pkg)
        continue
    if p not in db:
        continue
    order.append(p)
    for d in db[p][2]:
        if d not in seen:
            need.append(d)
if 'musl' not in seen and 'musl' in db:
    order.append('musl')
for p in order:
    v, fn, _ = db[p]
    print('%s|%s|%s' % (p, v, fn))
PY
}

download_apk() {
  local pkg="$1" ver="$2" fn="$3"
  local dest="$WORK/apks/$fn"
  [[ -f "$dest" ]] && return 0
  local m repo
  for repo in main community; do
    [[ -f "$WORK/idx/${repo}.mirror" ]] || continue
    m=$(cat "$WORK/idx/${repo}.mirror")
    if curl -fsSL -o "$dest" "$m/${repo}/${ARCH}/$fn"; then
      return 0
    fi
    rm -f "$dest"
  done
  echo "WARN: cannot download $fn" >&2
  return 1
}

extract_apk() {
  local apk="$1"
  local dir="$WORK/ex/$(basename "$apk" .apk)"
  rm -rf "$dir"; mkdir -p "$dir"
  # apk = tar.gz (sometimes)
  if ! tar -xzf "$apk" -C "$dir" 2>/dev/null; then
    tar -xf "$apk" -C "$dir"
  fi
  # merge into root (skip .PKGINFO etc)
  for sub in bin sbin usr lib etc share; do
    if [[ -d "$dir/$sub" ]]; then
      mkdir -p "$WORK/root/$sub"
      cp -a "$dir/$sub"/. "$WORK/root/$sub/" 2>/dev/null || true
    fi
  done
  if [[ -d "$dir/usr" ]]; then
    mkdir -p "$WORK/root/usr"
    cp -a "$dir/usr"/. "$WORK/root/usr/" 2>/dev/null || true
  fi
  if [[ -d "$dir/lib" ]]; then
    mkdir -p "$WORK/root/lib"
    cp -a "$dir/lib"/. "$WORK/root/lib/" 2>/dev/null || true
  fi
}

echo "==> resolve $NAME (${APKS[*]})"
RESOLVED_FILE="$WORK/idx/resolved.txt"
resolve > "$RESOLVED_FILE"
while IFS='|' read -r p v fn; do
  [[ -z "$p" ]] && continue
  echo "  apk $p $v"
  download_apk "$p" "$v" "$fn" || true
done < "$RESOLVED_FILE"

rm -rf "$WORK/root"
mkdir -p "$WORK/root"
for apk in "$WORK/apks"/*.apk; do
  [[ -f "$apk" ]] || continue
  extract_apk "$apk"
done

OUT="$ROOT/packages/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib"

# musl loader + libc
LOADER=$(find "$WORK/root" -name 'ld-musl-aarch64.so.1' | head -1)
[[ -n "$LOADER" ]] || { echo "no musl loader" >&2; exit 1; }
cp -a "$LOADER" "$OUT/lib/"
find "$WORK/root" -name 'libc.musl-aarch64.so.1' -exec cp -a {} "$OUT/lib/" \;
ln -sfn ld-musl-aarch64.so.1 "$OUT/lib/libc.so" 2>/dev/null || true

# all shared libs — symlink'и Alpine часто ../../lib/foo.so → копируем РЕАЛЬНЫЙ файл под SONAME
copy_lib() {
  local f="$1" base real
  base=$(basename "$f")
  case "$base" in
    ld-musl-aarch64.so.1) return 0 ;;
    # openssl engines — не нужны CLI, раздувают бандл
    afalg.so|capi.so|padlock.so|legacy.so|loader_attic.so) return 0 ;;
  esac
  if [[ -L "$f" ]]; then
    real=$(readlink -f "$f" 2>/dev/null || true)
    if [[ -z "$real" || ! -f "$real" ]]; then
      # macOS: нет readlink -f
      real=$(python3 -c "import os; print(os.path.realpath('$f'))" 2>/dev/null || true)
    fi
    if [[ -n "$real" && -f "$real" ]]; then
      cp -a "$real" "$OUT/lib/$base"
      return 0
    fi
    return 0
  fi
  [[ -f "$f" ]] && cp -a "$f" "$OUT/lib/$base"
}
while IFS= read -r f; do
  copy_lib "$f"
done < <(find "$WORK/root" \( -type f -o -type l \) -name '*.so*' 2>/dev/null || true)

# binaries: prefer usr/bin, bin, sbin
# (не pipefail+head: find по несуществующим path даёт exit 1)
find_bin() {
  local b="$1"
  local d f
  for d in "$WORK/root/usr/bin" "$WORK/root/bin" "$WORK/root/usr/sbin" "$WORK/root/sbin"; do
    [[ -d "$d" ]] || continue
    # файл или symlink (socat → socat1 и т.п.)
    if [[ -e "$d/$b" && -x "$d/$b" ]]; then
      echo "$d/$b"
      return 0
    fi
    f=$(find "$d" \( -type f -o -type l \) -name "$b" 2>/dev/null | head -1 || true)
    [[ -n "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

copy_bin() {
  local b="$1"
  local f real
  f=$(find_bin "$b") || return 1
  # разыменовать symlink → копируем реальный бинарь под именем b
  if [[ -L "$f" ]]; then
    real=$(readlink -f "$f" 2>/dev/null || readlink "$f")
    [[ "$real" != /* ]] && real="$(dirname "$f")/$real"
    cp -a "$real" "$OUT/bin/$b"
  else
    cp -a "$f" "$OUT/bin/$b"
  fi
  chmod +x "$OUT/bin/$b"
}

# primary + common helpers for multi-bin packages
if ! copy_bin "$BIN"; then
  f=""
  for d in "$WORK/root/usr/bin" "$WORK/root/bin"; do
    [[ -d "$d" ]] || continue
    f=$(find "$d" -type f -perm -111 2>/dev/null | head -1 || true)
    [[ -n "$f" ]] && break
  done
  [[ -n "$f" ]] || { echo "binary $BIN not found in $WORK/root" >&2; find "$WORK/root" -type f -perm -111 2>/dev/null | head -20 >&2; exit 1; }
  cp -a "$f" "$OUT/bin/$(basename "$f")"
  BIN=$(basename "$f")
fi

# extra bins for known packages
case "$NAME" in
  bind-tools|drill)
    for b in dig host nslookup delv; do copy_bin "$b" || true; done
    ;;
  iproute2)
    for b in ip ss bridge tc; do copy_bin "$b" || true; done
    ;;
  procps)
    for b in ps top free watch vmstat pgrep pkill; do copy_bin "$b" || true; done
    ;;
  coreutils)
    for b in ls cat cp mv rm mkdir ln pwd uname head tail sort uniq wc tr cut; do copy_bin "$b" || true; done
    ;;
  util-linux)
    for b in lsblk mount umount dmesg fdisk losetup; do copy_bin "$b" || true; done
    ;;
  openssl)
    copy_bin openssl || true
    ;;
  git)
    copy_bin git || true
    # git needs libexec — copy if small enough
    if [[ -d "$WORK/root/usr/libexec/git-core" ]]; then
      mkdir -p "$OUT/libexec"
      cp -a "$WORK/root/usr/libexec/git-core" "$OUT/libexec/"
    fi
    ;;
  aria2)
    copy_bin aria2c || true
    BIN=aria2c
    ;;
  netcat-openbsd)
    copy_bin nc || true
    BIN=nc
    ;;
  unzip)
    for b in unzip zipinfo; do copy_bin "$b" || true; done
    ;;
  zip)
    for b in zip zipcloak zipnote zipsplit; do copy_bin "$b" || true; done
    ;;
  xz)
    for b in xz unxz xzcat lzma unlzma; do copy_bin "$b" || true; done
    ;;
  zstd)
    for b in zstd zstdcat zstdless unzstd; do copy_bin "$b" || true; done
    ;;
  screen)
    copy_bin screen || true
    ;;
  mtr)
    copy_bin mtr || true
    copy_bin mtr-packet || true
    ;;
esac

# terminfo только для TUI
case "$NAME" in
  tmux|htop|ncdu|less|nano|bash|screen|fzf)
    mkdir -p "$OUT/share/terminfo"
    for term in xterm xterm-256color screen screen-256color tmux tmux-256color linux vt100 ansi dumb; do
      for base in "$WORK/root/usr/share/terminfo" "$WORK/root/etc/terminfo"; do
        # terminfo: первый символ имени = подкаталог
        sub=$(printf '%s' "$term" | cut -c1)
        src="$base/$sub/$term"
        if [[ -f "$src" ]]; then
          mkdir -p "$OUT/share/terminfo/$sub"
          cp -a "$src" "$OUT/share/terminfo/$sub/"
        fi
      done
    done
    ;;
esac

# portable wrapper
cat > "$OUT/${NAME}-run" <<EOF
#!/bin/sh
DIR=\$(CDPATH= cd -- "\$(dirname "\$0")" && pwd)
export LD_LIBRARY_PATH="\$DIR/lib:\${LD_LIBRARY_PATH:-}"
if [ -d "\$DIR/share/terminfo" ]; then
  export TERMINFO="\$DIR/share/terminfo"
fi
if [ -d "\$DIR/libexec/git-core" ]; then
  export GIT_EXEC_PATH="\$DIR/libexec/git-core"
fi
BIN="\$DIR/bin/${BIN}"
if [ ! -x "\$BIN" ]; then
  echo "${NAME}: missing \$BIN" >&2
  exit 127
fi
exec "\$DIR/lib/ld-musl-aarch64.so.1" "\$BIN" "\$@"
EOF
chmod +x "$OUT/${NAME}-run" "$OUT/bin/"* 2>/dev/null || true

# detect version from binary strings or apk
if [[ -z "$VER" ]]; then
  VER=$(python3 - <<PY
import re, pathlib
p=pathlib.Path("$OUT/bin/$BIN")
data=p.read_bytes()[:200000]
# crude
m=re.search(rb'(\d+\.\d+(?:\.\d+)?)', data)
print(m.group(1).decode() if m else "0.0.0")
PY
)
fi

# write .apkg-meta for pack-packages
cat > "$OUT/.apkg-meta" <<EOF
version=$VER
category=$CAT
kind=dir
dest=/data/local/opt/$NAME
check=/data/local/opt/$NAME/bin/$BIN
description=$DESC
bin=$BIN
EOF

echo "OK $NAME v$VER → $OUT ($(du -sh "$OUT" | awk '{print $1}')) bins: $(ls "$OUT/bin" | tr '\n' ' ')"
