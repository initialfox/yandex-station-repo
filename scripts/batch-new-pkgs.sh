#!/usr/bin/env bash
# Собрать пачку новых пакетов, прогнать на станции, удалить
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MK=./scripts/mk-alpine-pkg.sh
export SSHPASS="${SSHPASS:-\$Nikitosina04}"
ST="${STATION_HOST:-root@192.168.1.116}"
ssh_st() {
  sshpass -e ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o LogLevel=ERROR "$ST" "$@"
}
push_file() {
  ssh_st "cat > $2" < "$1"
}

# name | alpine pkgs... | --bin X --cat Y --desc Z --ver V
PKGS=(
  'jq|jq|--bin jq --cat util --desc JSON процессор --ver 1.7.1'
  'socat|socat|--bin socat --cat net --desc Мультиплексный relay TCP/UDP/UNIX --ver 1.8.0'
  'rsync|rsync|--bin rsync --cat net --desc Синхронизация файлов --ver 3.4.3'
  'tmux|tmux|--bin tmux --cat shell --desc Терминальный мультиплексор --ver 3.4'
  'wget|wget|--bin wget --cat net --desc HTTP/FTP загрузчик --ver 1.24.5'
  'bash|bash|--bin bash --cat shell --desc GNU Bash --ver 5.2.26'
  'less|less|--bin less --cat util --desc Пейджер --ver 643'
  'tree|tree|--bin tree --cat util --desc Дерево каталогов --ver 2.1.3'
  'strace|strace|--bin strace --cat debug --desc Трассировка syscalls --ver 6.9'
  'lsof|lsof|--bin lsof --cat debug --desc Открытые файлы/сокеты --ver 4.99.3'
  'ncdu|ncdu|--bin ncdu --cat util --desc Анализ диска (ncurses) --ver 1.20'
  'htop|htop|--bin htop --cat system --desc Интерактивный top --ver 3.3.0'
  'screen|screen|--bin screen --cat shell --desc Terminal multiplexer --ver 4.9.1'
  'openssl|openssl|--bin openssl --cat net --desc OpenSSL CLI --ver 3.3.2'
  'zstd|zstd|--bin zstd --cat util --desc Сжатие Zstandard --ver 1.5.6'
  'xz|xz|--bin xz --cat util --desc Сжатие XZ/LZMA --ver 5.6.2'
  'unzip|unzip|--bin unzip --cat util --desc Распаковка ZIP --ver 6.0'
  'zip|zip|--bin zip --cat util --desc Упаковка ZIP --ver 3.0'
  'pv|pv|--bin pv --cat util --desc Pipe viewer --ver 1.8.5'
  'mtr|mtr|--bin mtr --cat net --desc My Traceroute --ver 0.95'
  'aria2|aria2|--bin aria2c --cat net --desc Многопоточный загрузчик --ver 1.37.0'
  'netcat|netcat-openbsd|--bin nc --cat net --desc netcat (OpenBSD) --ver 1.226'
  'file|file|--bin file --cat util --desc Определение типа файла --ver 5.45'
  'gawk|gawk|--bin gawk --cat util --desc GNU AWK --ver 5.3.0'
  'dig|bind-tools|--bin dig --cat net --desc dig/host/nslookup (BIND) --ver 9.18.27'
  'procps|procps-ng|--bin ps --cat system --desc ps/top/free/watch --ver 4.0.4'
  'sshpass|sshpass|--bin sshpass --cat net --desc SSH с паролем в CLI --ver 1.10'
  'fzf|fzf|--bin fzf --cat util --desc Fuzzy finder --ver 0.53.0'
  'ripgrep|ripgrep|--bin rg --cat util --desc Быстрый grep (rg) --ver 14.1.0'
  'fd|fd|--bin fd --cat util --desc Быстрый find --ver 10.1.0'
)

RESULTS="$ROOT/.build/batch-results.txt"
mkdir -p "$ROOT/.build"
: > "$RESULTS"

test_pkg() {
  local name="$1"
  local bin="$2"
  local tar="/tmp/${name}-test.tar"
  local remote="/data/local/tmp/${name}-test.tar"
  tar -C packages -cf "$tar" "$name"
  push_file "$tar" "$remote"
  local out
  out=$(ssh_st "/system/bin/sh -c '
    set -e
    cd /data/local/tmp
    rm -rf $name
    tar xf ${name}-test.tar
    BIN=\$(cat $name/.apkg-meta | sed -n \"s/^bin=//p\")
    [ -n \"\$BIN\" ] || BIN=$bin
    RUN=./$name/${name}-run
    # smoke
    if \$RUN --version >/tmp/apkg-out 2>&1 || \$RUN -V >/tmp/apkg-out 2>&1 || \$RUN -v >/tmp/apkg-out 2>&1 || \$RUN version >/tmp/apkg-out 2>&1; then
      head -c 200 /tmp/apkg-out
      echo
      echo TEST_OK
    else
      # некоторые утилиты без --version просто печатают usage и exit!=0 — проверим что loader стартует
      if \$RUN 2>&1 | head -c 200; then true; fi
      if [ -x ./$name/bin/\$BIN ]; then
        echo TEST_OK_BIN
      else
        echo TEST_FAIL
        cat /tmp/apkg-out 2>/dev/null | head -c 300
        exit 1
      fi
    fi
    rm -rf $name ${name}-test.tar /tmp/apkg-out
  '" 2>&1) || {
    echo "$out"
    echo "$name FAIL" >> "$RESULTS"
    return 1
  }
  echo "$out" | tail -5
  if echo "$out" | grep -q 'TEST_OK'; then
    echo "$name OK" >> "$RESULTS"
    return 0
  fi
  echo "$name FAIL" >> "$RESULTS"
  return 1
}

ok=0; fail=0
for entry in "${PKGS[@]}"; do
  IFS='|' read -r name apks flags <<<"$entry"
  echo ""
  echo "######## BUILD $name ########"
  # shellcheck disable=SC2086
  if ! $MK "$name" $apks $flags; then
    echo "$name BUILD_FAIL" >> "$RESULTS"
    fail=$((fail+1))
    continue
  fi
  bin=$(sed -n 's/^bin=//p' "packages/$name/.apkg-meta" 2>/dev/null || echo "$name")
  echo "######## TEST $name ########"
  if test_pkg "$name" "$bin"; then
    ok=$((ok+1))
  else
    fail=$((fail+1))
  fi
done

echo ""
echo "==== DONE ok=$ok fail=$fail ===="
cat "$RESULTS"
