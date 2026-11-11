#!/usr/bin/env bash
# Собрать musl-бандл из Alpine aarch64 APK → packages/<name>/
# Usage: ./scripts/mk-alpine-pkg.sh <name> <apk> [apk...] [--bin binary] [--ver X] [--cat Y] [--desc Z] [--perl-full]
# Главная программа — ELF или скрипт на sh/bash/perl (интерпретатор кладётся в пакет).
# --perl-full — не вырезать из perl тяжёлые редко нужные модули (CJK-кодировки, Collate, dev-утилиты).
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
PERL_FULL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    --cat) CAT="$2"; shift 2 ;;
    --desc) DESC="$2"; shift 2 ;;
    --perl-full) PERL_FULL=1; shift ;;
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

# real_path <путь> — как readlink -f (которого нет в старом macOS), но абсолютная
# ссылка из APK (/usr/lib/…) разрешается внутри $WORK/root, а не в файл хоста
real_path() {
  local p="$1" t n=0
  while [[ -L "$p" && $n -lt 40 ]]; do
    t=$(readlink "$p") || return 1
    case "$t" in
      /*) p="$WORK/root$t" ;;
      *) p="$(dirname "$p")/$t" ;;
    esac
    n=$((n + 1))
  done
  [[ -f "$p" ]] || return 1
  printf '%s\n' "$p"
}

# place_lib <файл> <имя> — положить файл в $OUT/lib/<имя>, если этого имени там ещё нет
place_lib() {
  local src="$1" dst="$OUT/lib/$2"
  if [[ -e "$dst" || -L "$dst" ]]; then
    cmp -s "$src" "$dst" || echo "WARN: lib/$2: другой файл с тем же именем ($src) пропущен" >&2
    return 0
  fi
  cp -p "$src" "$dst"
}

# Общие .so → $OUT/lib (плоско: их ищет загрузчик по LD_LIBRARY_PATH / --library-path).
# Алиас (symlink Alpine: libz.so.1 → libz.so.1.3.2, usr/lib/x.so → ../../lib/x.so.1)
# становится symlink'ом на один реальный файл — раньше каждый алиас был полной копией.
# XS-модули perl (perl5/…/auto/*.so) сюда не кладём: perl ищет их в auto/<Модуль>/
# рядом с .pm (дерево копирует bundle_perl), а при плоском копировании одноимённые
# затирали друг друга (List::Util и Hash::Util — оба Util.so).
copy_lib() {
  local f="$1" base real rbase
  base=$(basename "$f")
  case "$base" in
    ld-musl-aarch64.so.1) return 0 ;;
    # openssl engines — не нужны CLI, раздувают бандл
    afalg.so|capi.so|padlock.so|legacy.so|loader_attic.so) return 0 ;;
  esac
  case "$f" in
    */perl5/*/CORE/libperl.so) ;; # libperl нужен самому бинарю perl — в общий lib/
    */perl5/*) return 0 ;;
  esac
  if [[ -L "$f" ]]; then
    real=$(real_path "$f") || return 0
    rbase=$(basename "$real")
    place_lib "$real" "$rbase"
    if [[ "$base" != "$rbase" && ! -e "$OUT/lib/$base" && ! -L "$OUT/lib/$base" ]]; then
      ln -s "$rbase" "$OUT/lib/$base"
    fi
    return 0
  fi
  if [[ -f "$f" ]]; then
    place_lib "$f" "$base"
  fi
  return 0
}
# сначала lib/ и usr/lib/ верхнего уровня, потом подкаталоги: при совпадении имён
# остаётся настоящая библиотека, а не одноимённый плагин
while IFS= read -r f; do
  copy_lib "$f"
done < <(find "$WORK/root" \( -type f -o -type l \) -name '*.so*' 2>/dev/null \
  | awk -F/ '{ print NF "\t" $0 }' | sort -s -n -k1,1 | cut -f2- || true)

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
    real=$(real_path "$f") || return 1
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

# script_interp <файл> → «ELF», «<интерпретатор><TAB><аргументы>» или пусто (непонятный файл)
script_interp() {
  python3 - "$1" <<'PY'
import os, sys
with open(sys.argv[1], "rb") as f:
    head = f.read(512)
if head.startswith(b"\x7fELF"):
    print("ELF")
elif head.startswith(b"#!"):
    words = head[2:].split(b"\n", 1)[0].decode("utf-8", "replace").split()
    if words and os.path.basename(words[0]) == "env":
        words = words[1:]
        while words and words[0].startswith("-"):  # env -S …
            words = words[1:]
    if words:
        print(os.path.basename(words[0]) + "\t" + " ".join(words[1:]))
PY
}

# perl-скрипт: кладём perl, libperl.so (уже в lib/) и деревья модулей с исходной
# структурой каталогов; вырезаем тяжёлое и почти никогда не нужное, если скрипт на
# это не ссылается. Заполняет RUN_ENV — окружение для обёртки.
bundle_perl() {
  copy_bin perl || { echo "ERROR: $BIN — perl-скрипт, а perl нет среди зависимостей (добавь apk perl)" >&2; exit 1; }
  [[ -f "$OUT/lib/libperl.so" ]] || { echo "ERROR: нет libperl.so для perl" >&2; exit 1; }
  local inc d p5="" p5d=""
  inc=$(python3 - "$WORK/root" "$OUT" "$OUT/bin/$BIN" "$PERL_FULL" <<'PY'
import os, re, shutil, sys

root, out, script, full = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
# каталог Alpine → каталог в пакете; порядок = порядок @INC у Alpine (vendor, потом core)
TREES = [
    ("usr/lib/perl5/vendor_perl", "lib/perl5/vendor_perl"),
    ("usr/share/perl5/vendor_perl", "share/perl5/vendor_perl"),
    ("usr/lib/perl5/core_perl", "lib/perl5/core_perl"),
    ("usr/share/perl5/core_perl", "share/perl5/core_perl"),
]
inc = []
for src, dst in TREES:
    s = os.path.join(root, src)
    if not os.path.isdir(s) or not os.listdir(s):
        continue
    # CORE/ — это libperl.so (он уже в lib/): в дерево модулей не нужен
    skip_core = lambda d, names, s=s: ["CORE"] if os.path.samefile(d, s) and "CORE" in names else []
    shutil.copytree(s, os.path.join(out, dst), symlinks=True, ignore=skip_core)
    inc.append(dst)
if not inc:
    sys.exit("ERROR: в зависимостях нет модулей perl (usr/lib/perl5, usr/share/perl5)")

# Модули, на которые скрипт ссылается (use/require, в том числе внутри строк для
# perl -e и eval), транзитивно по .pm. Это страховка для вырезания ниже, а не точный
# список: динамический require $x так не виден.
POD = re.compile(rb"^=[a-zA-Z].*?(?:^=cut\b[^\n]*|\Z)", re.M | re.S)
USE = re.compile(rb"\b(?:use|require)\s+([A-Za-z_]\w*(?:::\w+)*)")

def find_pm(mod):
    rel = mod.replace("::", "/") + ".pm"
    for d in inc:
        if os.path.isfile(os.path.join(out, d, rel)):
            return d, rel
    return None

needed, missing, seen, queue = set(), set(), set(), [script]
while queue:
    with open(queue.pop(), "rb") as f:
        text = f.read()
    text = re.split(rb"(?m)^__(?:END|DATA)__\b", text, maxsplit=1)[0]
    for m in USE.finditer(POD.sub(b"", text)):
        mod = m.group(1).decode()
        if mod in seen:
            continue
        seen.add(mod)
        hit = find_pm(mod)
        if hit:
            needed.add(hit[1])
            queue.append(os.path.join(out, *hit))
        elif "::" in mod or (mod.isupper() and len(mod) > 1):  # не «Foo»/«C» из комментариев
            missing.add(mod)

# Тяжёлое и почти никогда не нужное CLI-скрипту (~19 МБ из ~39 МБ perl в Alpine 3.20)
PRUNE = {
    "Encode::JP": ["Encode/JP.pm", "Encode/JP", "auto/Encode/JP"],
    "Encode::KR": ["Encode/KR.pm", "Encode/KR", "auto/Encode/KR"],
    "Encode::CN": ["Encode/CN.pm", "Encode/CN", "auto/Encode/CN"],
    "Encode::TW": ["Encode/TW.pm", "Encode/TW", "auto/Encode/TW"],
    "Unicode::Collate": ["Unicode/Collate.pm", "Unicode/Collate", "auto/Unicode/Collate"],
    "Module::CoreList": ["Module/CoreList.pm", "Module/CoreList"],
    # сборка/установка модулей, тесты, отладчик, perldoc
    "CPAN": ["CPAN.pm", "CPAN"],
    "ExtUtils": ["ExtUtils"],
    "TAP": ["TAP"],
    "Test": ["Test.pm", "Test"],
    "Test2": ["Test2.pm", "Test2"],
    "App": ["App"],
    "perl5db": ["perl5db.pl"],
    "Pod::Perldoc": ["Pod/Perldoc.pm", "Pod/Perldoc"],
}

def size(p):
    if os.path.isdir(p) and not os.path.islink(p):
        return sum(os.lstat(os.path.join(a, n)).st_size for a, _, ns in os.walk(p) for n in ns)
    return os.lstat(p).st_size

def remove(p):
    # .pm в Alpine — 0444: сначала вернуть право записи (каталог 0555 иначе не удалить)
    if os.path.isdir(p) and not os.path.islink(p):
        for a, _, ns in os.walk(p):
            os.chmod(a, 0o755)
            for n in ns:
                if not os.path.islink(os.path.join(a, n)):
                    os.chmod(os.path.join(a, n), 0o644)
        shutil.rmtree(p)
    else:
        if not os.path.islink(p):
            os.chmod(p, 0o644)
        os.remove(p)

cut, kept, removed = [], [], 0
if not full:
    for group, paths in PRUNE.items():
        if any(rel == p or rel.startswith(p + "/") for rel in needed for p in paths):
            kept.append(group)
            continue
        for d in inc:
            for p in paths:
                q = os.path.join(out, d, p)
                if not os.path.lexists(q):
                    continue
                removed += size(q)
                remove(q)
        cut.append(group)

say = lambda s: print("  perl: " + s, file=sys.stderr)
say("модулей, на которые ссылается %s: %d" % (os.path.basename(script), len(needed)))
if missing:
    say("нет в сборке (обычно необязательные, не из core): " + ", ".join(sorted(missing)))
if kept:
    say("не вырезаю, на них ссылается скрипт: " + ", ".join(kept))
if cut:
    say("вырезано %.1f МБ: %s (оставить всё: --perl-full)" % (removed / 1e6, ", ".join(cut)))
print(" ".join(inc))
PY
) || exit 1
  for d in $inc; do
    p5="${p5:+$p5:}\$DIR/$d"
    p5d="${p5d:+$p5d:}\$D/$d"
  done
  # parallel и подобные сами запускают «perl -e …» через PATH, а голый bin/perl без
  # загрузчика на станции не стартует — кладём обёртку-perl в libexec/bin
  mkdir -p "$OUT/libexec/bin"
  cat > "$OUT/libexec/bin/perl" <<EOF
#!/bin/sh
# perl пакета для дочерних «perl …»: ${NAME}-run добавляет этот каталог в PATH
D=\$(CDPATH= cd -- "\$(dirname "\$0")/../.." && pwd)
export PERL5LIB="\${PERL5LIB:-${p5d}}"
exec "\$D/lib/ld-musl-aarch64.so.1" --library-path "\$D/lib" "\$D/bin/perl" "\$@"
EOF
  chmod +x "$OUT/libexec/bin/perl"
  RUN_ENV="export PERL5LIB=\"${p5}\${PERL5LIB:+:\$PERL5LIB}\"
export PATH=\"\$DIR/libexec/bin:\$PATH\"
# временные файлы — в \$TMPDIR или /tmp, а /tmp на Android нет
if [ -z \"\${TMPDIR:-}\" ] && [ ! -w /tmp ] && [ -w /data/local/tmp ]; then
  export TMPDIR=/data/local/tmp
fi
"
}

# Главная программа — ELF или скрипт? Обёртка «ld-musl <файл>» годится только для ELF:
# скрипт загрузчик отвергает («Not a valid dynamic program» — так сломался parallel).
# Скрипту кладём интерпретатор; непонятный файл или интерпретатор — не собираем.
LIB_ENV='export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH:-}"'$'\n'
RUN_ENV=""
EXEC_LINE='exec "$DIR/lib/ld-musl-aarch64.so.1" "$BIN" "$@"'
KIND=$(script_interp "$OUT/bin/$BIN")
case "$KIND" in
  ELF) ;;
  "")
    echo "ERROR: $OUT/bin/$BIN — не ELF и не скрипт с #!" >&2
    exit 1
    ;;
  *)
    INTERP=${KIND%%$'\t'*}
    IARGS=${KIND#*$'\t'}
    IARGS=${IARGS:+$IARGS }
    # Библиотеки интерпретатора — через --library-path, а не LD_LIBRARY_PATH: иначе
    # musl-библиотеки пакета унаследуют системные программы, которые запускает скрипт
    LIB_ENV=""
    case "$INTERP" in
      sh | ash | dash)
        EXEC_LINE="exec /bin/sh ${IARGS}\"\$BIN\" \"\$@\""
        ;;
      bash)
        copy_bin bash || { echo "ERROR: $BIN — bash-скрипт, а bash нет среди зависимостей (добавь apk bash)" >&2; exit 1; }
        EXEC_LINE="exec \"\$DIR/lib/ld-musl-aarch64.so.1\" --library-path \"\$DIR/lib\" \"\$DIR/bin/bash\" ${IARGS}\"\$BIN\" \"\$@\""
        ;;
      perl | perl5*)
        bundle_perl
        EXEC_LINE="exec \"\$DIR/lib/ld-musl-aarch64.so.1\" --library-path \"\$DIR/lib\" \"\$DIR/bin/perl\" ${IARGS}\"\$BIN\" \"\$@\""
        ;;
      *)
        echo "ERROR: $BIN — скрипт на «$INTERP», а сборщик умеет только sh, bash и perl. Добавь поддержку в mk-alpine-pkg.sh или собери пакет вручную" >&2
        exit 1
        ;;
    esac
    echo "  $BIN — скрипт на $INTERP: интерпретатор в пакете"
    ;;
esac

# portable wrapper
cat > "$OUT/${NAME}-run" <<EOF
#!/bin/sh
DIR=\$(CDPATH= cd -- "\$(dirname "\$0")" && pwd)
${LIB_ENV}if [ -d "\$DIR/share/terminfo" ]; then
  export TERMINFO="\$DIR/share/terminfo"
fi
if [ -d "\$DIR/libexec/git-core" ]; then
  export GIT_EXEC_PATH="\$DIR/libexec/git-core"
fi
${RUN_ENV}BIN="\$DIR/bin/${BIN}"
if [ ! -x "\$BIN" ]; then
  echo "${NAME}: missing \$BIN" >&2
  exit 127
fi
${EXEC_LINE}
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
