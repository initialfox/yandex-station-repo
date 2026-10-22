#!/usr/bin/env bash
# Один пакет: build → тест на станции → pack → pkg/main → git → TG
# Usage: ./scripts/one-pkg.sh <name> <apk...> [--bin X] [--cat Y] [--desc Z] [--ver V]
#        ./scripts/one-pkg.sh --why "что изменено" ...  # для обновления
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WHY=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --why) WHY="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ ${#ARGS[@]} -ge 2 ]] || { echo "usage: $0 [--why text] name apk... [flags]"; exit 2; }

NAME="${ARGS[0]}"
export SSHPASS="${SSHPASS:-\$Nikitosina04}"
ST="${STATION_HOST:-root@192.168.1.116}"
TOKEN_TG="${TG_BOT_TOKEN:-8722487193:AAH88lJ7ZFeBfEyFaewlDSE3zl3UNjcenQk}"

ssh_st() {
  sshpass -e ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o LogLevel=ERROR -o ConnectTimeout=20 "$ST" "$@"
}

echo "======== BUILD $NAME ========"
./scripts/mk-alpine-pkg.sh "${ARGS[@]}"
META="packages/$NAME/.apkg-meta"
test -f "$META"
BIN=$(sed -n 's/^bin=//p' "$META")
VER=$(sed -n 's/^version=//p' "$META")
DESC=$(sed -n 's/^description=//p' "$META")
CAT=$(sed -n 's/^category=//p' "$META")

echo "======== TEST $NAME on station ========"
tar -C packages -cf "/tmp/${NAME}-one.tar" "$NAME"
ssh_st "cat > /data/local/tmp/${NAME}-one.tar" < "/tmp/${NAME}-one.tar"
OUT=$(ssh_st "/system/bin/sh -c '
  export ANDROID_DATA=/data ANDROID_ROOT=/system
  cd /data/local/tmp || exit 1
  rm -rf $NAME
  tar xf ${NAME}-one.tar || exit 1
  RUN=./$NAME/${NAME}-run
  OV=/data/local/tmp/apkg-ov.txt
  ok=0
  \$RUN --version >\$OV 2>&1 || true
  if grep -qiE \"Error loading shared library|cannot open shared object\" \$OV; then
    ok=0
  elif grep -qiE \"[0-9]+\\.[0-9]+|usage|Usage|option|Syntax|socat\" \$OV; then
    ok=1
  else
    \$RUN -V >\$OV 2>&1 || \$RUN -h >\$OV 2>&1 || \$RUN >\$OV 2>&1 || true
    if grep -qiE \"Error loading shared library|cannot open shared object\" \$OV; then
      ok=0
    elif grep -qiE \"[0-9]+\\.[0-9]+|usage|Usage|option|Syntax\" \$OV; then
      ok=1
    fi
  fi
  dd if=\$OV bs=240 count=1 2>/dev/null; echo
  rm -rf $NAME ${NAME}-one.tar \$OV
  [ \$ok = 1 ] && echo TEST_OK || echo TEST_FAIL
'")
echo "$OUT"
echo "$OUT" | grep -q TEST_OK || { echo "TEST FAILED for $NAME"; exit 1; }
rm -f "/tmp/${NAME}-one.tar"

echo "======== PACK + PUSH ========"
mkdir -p dist
export COPYFILE_DISABLE=1
tar -C packages -cf "dist/${NAME}.tar" "$NAME"
python3 - "$NAME" <<'PY'
import hashlib, json, os, sys
name = sys.argv[1]
meta = {}
for line in open(f"packages/{name}/.apkg-meta"):
    if "=" in line:
        k, v = line.strip().split("=", 1)
        meta[k] = v
h = hashlib.md5(open(f"dist/{name}.tar", "rb").read()).hexdigest()
size = os.path.getsize(f"dist/{name}.tar")
d = json.load(open("packages.json"))
entry = {
    "name": name,
    "version": meta.get("version", "0.0.0"),
    "arch": "aarch64",
    "description": meta.get("description", name),
    "category": meta.get("category", "misc"),
    "kind": meta.get("kind", "dir"),
    "asset": f"{name}.tar",
    "bin": meta.get("bin", name),
    "dest": meta.get("dest", f"/data/local/opt/{name}"),
    "check": meta.get("check", f"/data/local/opt/{name}/bin/{meta.get('bin', name)}"),
    "md5": h,
    "size": size,
}
pkgs = {p["name"]: p for p in d["packages"]}
is_new = name not in pkgs
pkgs[name] = entry
d["packages"] = [pkgs[k] for k in sorted(pkgs)]
open("packages.json", "w").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
open("/tmp/apkg-is-new", "w").write("1" if is_new else "0")
print(name, "new" if is_new else "upd", h, size)
PY
IS_NEW=$(cat /tmp/apkg-is-new)

# ветка pkg — shallow clone (Contents API на больших tar зависает)
PKG_TMP=$(mktemp -d)
git clone --depth 1 -b pkg "https://github.com/initialfox/yandex-station-repo.git" "$PKG_TMP"
cp "dist/${NAME}.tar" "$PKG_TMP/"
cp packages.json "$PKG_TMP/packages.json"
(
  cd "$PKG_TMP"
  git config http.postBuffer 524288000
  git add "${NAME}.tar" packages.json
  git -c user.email="apkg@local" -c user.name="apkg" commit -m "apkg: ${NAME} ${VER}" || true
  git push origin pkg
)
rm -rf "$PKG_TMP"
echo "pkg branch updated"

# main — исходники + packages.json
git add "packages/$NAME" packages.json scripts/mk-alpine-pkg.sh scripts/one-pkg.sh 2>/dev/null || true
git add "packages/$NAME" packages.json
# убрать мешающий WIP
git stash push -u -m "wip-other-pkgs" -- packages/rsync packages/tmux packages/wget 2>/dev/null || true
if ! git diff --cached --quiet || ! git diff --quiet -- packages.json "packages/$NAME" 2>/dev/null; then
  git commit -m "apkg: ${NAME} ${VER}" || true
fi
git pull --rebase origin main
git push origin HEAD
git stash pop 2>/dev/null || true

echo "======== TG ========"
if [[ "$IS_NEW" == "1" ]]; then
  TITLE="📦 <b>добавлен пакет</b> · <code>${NAME}</code>"
  WHY_BLOCK=""
else
  TITLE="🔄 <b>обновлён пакет</b> · <code>${NAME}</code>"
  WHY_BLOCK=$'\n'"<blockquote>${WHY:-обновление бандла / зависимостей}</blockquote>"$'\n'
fi

TEXT=$(cat <<EOF
${TITLE}

<blockquote>${DESC}
версия <b>${VER}</b> · aarch64 · Alpine musl · ${CAT}</blockquote>
${WHY_BLOCK}
Установка:
<pre>apkg update
apkg install ${NAME}
${BIN} --version</pre>

🔗 <a href="https://github.com/initialfox/yandex-station-repo">yandex-station-repo</a>
EOF
)

curl -sS -X POST "https://api.telegram.org/bot${TOKEN_TG}/sendMessage" \
  --data-urlencode chat_id=@apkg_repo \
  --data-urlencode parse_mode=HTML \
  --data-urlencode disable_web_page_preview=true \
  --data-urlencode text="$TEXT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok"), d; print("TG msg", d["result"]["message_id"])'

echo "======== DONE $NAME ========"
