#!/usr/bin/env bash
# Один пакет: build → тест на станции → pack → commit → pkg (архив) → main (git push) → pkg (индекс) → TG
# Usage: ./scripts/one-pkg.sh <name> <apk...> [--bin X] [--cat Y] [--desc Z] [--ver V]
#        ./scripts/one-pkg.sh --why "что изменено" ...  # для обновления
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/tar-flags.sh"

die() {
  echo "ОШИБКА: $*" >&2
  exit 1
}

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

# main обновляется обычным git push (индекс вместе с packages/<name>), поэтому
# сначала догоняем origin/main: правим свежий индекс, а конфликт видим до сборки
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "скрипт публикует в main — переключись на ветку main"
if ! git pull --rebase --autostash origin main; then
  git rebase --abort 2>/dev/null || true
  die "git pull --rebase origin main не прошёл — разреши конфликт и запусти снова"
fi

echo "======== BUILD $NAME ========"
./scripts/mk-alpine-pkg.sh "${ARGS[@]}"
META="packages/$NAME/.apkg-meta"
test -f "$META"
BIN=$(sed -n 's/^bin=//p' "$META")
VER=$(sed -n 's/^version=//p' "$META")
DESC=$(sed -n 's/^description=//p' "$META")
CAT=$(sed -n 's/^category=//p' "$META")

echo "======== TEST $NAME on station ========"
# сама проверка — scripts/station-smoke.sh (общая с batch-*.sh)
tar_c -C packages -cf "/tmp/${NAME}-one.tar" "$NAME"
ssh_st "cat > /data/local/tmp/${NAME}-one.tar" < "/tmp/${NAME}-one.tar"
ssh_st "cat > /data/local/tmp/apkg-smoke.sh" < scripts/station-smoke.sh
rm -f "/tmp/${NAME}-one.tar"
OUT=$(ssh_st "/system/bin/sh /data/local/tmp/apkg-smoke.sh /data/local/tmp/${NAME}-one.tar $NAME $BIN" 2>&1) || true
echo "$OUT"
echo "$OUT" | grep -qx TEST_OK || die "TEST FAILED for $NAME"

echo "======== PACK ========"
mkdir -p dist
tar_c -C packages -cf "dist/${NAME}.tar" "$NAME"
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

echo "======== COMMIT main ========"
# Раньше main получал packages.json через Contents API, а коммит с packages/<name>
# молча терялся (git pull/push … || true). Теперь индекс и исходники уходят одним
# коммитом, и любая ошибка git останавливает скрипт до анонса в TG.
git add -- "packages/$NAME" packages.json
# правки сборщика и скриптов публикации едут вместе с пакетом (как раньше)
git add -- scripts/mk-alpine-pkg.sh scripts/one-pkg.sh scripts/station-smoke.sh scripts/tar-flags.sh
if git diff --cached --quiet; then
  echo "main: нечего коммитить"
else
  git commit -m "apkg: ${NAME} ${VER}"
fi
# конфликт ловим до публикации архива
if ! git pull --rebase --autostash origin main; then
  git rebase --abort 2>/dev/null || true
  die "git pull --rebase origin main не прошёл — ничего не опубликовано; разреши конфликт и запусти снова"
fi

# gh_put <путь в репо> <локальный файл> <сообщение коммита> <ветка>
# GitHub Contents API (timeout 600s) — clone ветки pkg слишком тяжёлый
gh_put() {
  python3 - "$@" <<'PY'
import base64, json, os, sys, urllib.request, ssl
path, local, msg, branch = sys.argv[1:5]
def github_token():
    for cmd in (
        "gh auth token",
        "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill",
    ):
        out = os.popen(cmd).read()
        if cmd.startswith("printf"):
            for line in out.splitlines():
                if line.startswith("password="):
                    t = line.split("=", 1)[1].strip()
                    if t:
                        return t
        else:
            t = out.strip()
            if t and "not logged" not in t.lower():
                return t
    for k in ("GH_TOKEN", "GITHUB_TOKEN"):
        t = os.environ.get(k, "").strip()
        if t:
            return t
    raise SystemExit("no github token (gh auth / git credential / GH_TOKEN)")

token = github_token()
repo = "initialfox/yandex-station-repo"
ctx = ssl.create_default_context()

def put(path, data, msg, branch, tries=4):
    api = f"https://api.github.com/repos/{repo}/contents/{path}"
    content = base64.b64encode(data).decode()
    for attempt in range(tries):
        req = urllib.request.Request(
            api + f"?ref={branch}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "apkg"},
        )
        sha = None
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
                sha = json.load(r)["sha"]
        except Exception:
            pass
        body = {"message": msg, "content": content, "branch": branch}
        if sha:
            body["sha"] = sha
        req = urllib.request.Request(
            api,
            data=json.dumps(body).encode(),
            method="PUT",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "User-Agent": "apkg",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=600) as r:
                print("OK", path, branch, json.load(r)["commit"]["sha"][:12])
                return
        except Exception as e:
            if "409" in str(e) and attempt + 1 < tries:
                print("retry 409", path, branch, attempt + 1)
                continue
            raise

put(path, open(local, "rb").read(), msg, branch)
PY
}

echo "======== PUSH pkg: ${NAME}.tar ========"
gh_put "${NAME}.tar" "dist/${NAME}.tar" "apkg: ${NAME} ${VER}" pkg

echo "======== PUSH main ========"
git push origin HEAD:main || die "git push в main не прошёл: ${NAME}.tar уже в ветке pkg, а индекс в main старый — исправь причину и выполни «git push origin HEAD:main»"

echo "======== PUSH pkg: packages.json ========"
# запасной индекс apkg (indexFallbacks) — копия main
gh_put packages.json packages.json "packages.json: ${NAME}" pkg

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
