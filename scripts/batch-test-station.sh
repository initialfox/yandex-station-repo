#!/usr/bin/env bash
# Прогнать packages/<name> на станции: push → run → удалить
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SSHPASS="${SSHPASS:-\$Nikitosina04}"
ST="${STATION_HOST:-root@192.168.1.116}"
RESULTS="$ROOT/.build/batch-test-results.txt"
mkdir -p .build
: > "$RESULTS"

ssh_st() {
  sshpass -e ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no -o LogLevel=ERROR -o ConnectTimeout=15 "$ST" "$@"
}

# список новых пакетов (есть .apkg-meta)
NAMES=()
for d in packages/*/; do
  n=$(basename "$d")
  [[ -f "packages/$n/.apkg-meta" ]] || continue
  NAMES+=("$n")
done

ok=0; fail=0
for name in "${NAMES[@]}"; do
  bin=$(sed -n 's/^bin=//p' "packages/$name/.apkg-meta")
  [[ -n "$bin" ]] || bin=$name
  echo "######## TEST $name ($bin) ########"
  tar -C packages -cf "/tmp/${name}-t.tar" "$name"
  if ! ssh_st "cat > /data/local/tmp/${name}-t.tar" < "/tmp/${name}-t.tar"; then
    echo "$name PUSH_FAIL" | tee -a "$RESULTS"
    fail=$((fail+1))
    continue
  fi
  out=$(ssh_st "/system/bin/sh -c '
    export ANDROID_DATA=/data ANDROID_ROOT=/system
    cd /data/local/tmp || exit 1
    rm -rf $name
    tar xf ${name}-t.tar || exit 1
    RUN=./$name/${name}-run
    BIN=./$name/bin/$bin
    ok=0
    if [ -x \"\$RUN\" ]; then
      \$RUN --version >/tmp/ov 2>&1 && ok=1
      \$RUN -V >/tmp/ov 2>&1 && ok=1
      \$RUN -v >/tmp/ov 2>&1 && ok=1
      # smoke: loader стартует
      if [ \"\$ok\" = 0 ] && \$RUN 2>/tmp/ov; then ok=1; fi
      if [ \"\$ok\" = 0 ] && head -c 1 /tmp/ov >/dev/null 2>&1; then
        # usage на stderr тоже ок если бинарь жив
        if grep -qiE \"usage|option|version|[0-9]+\\.[0-9]+\" /tmp/ov 2>/dev/null; then ok=1; fi
      fi
    fi
    if [ \"\$ok\" = 0 ] && [ -x \"\$BIN\" ]; then
      # прямой запуск через loader
      LOADER=./$name/lib/ld-musl-aarch64.so.1
      if [ -x \"\$LOADER\" ]; then
        LD_LIBRARY_PATH=./$name/lib \"\$LOADER\" \"\$BIN\" --version >/tmp/ov 2>&1 && ok=1
      fi
    fi
    head -c 160 /tmp/ov 2>/dev/null; echo
    rm -rf $name ${name}-t.tar /tmp/ov
    [ \"\$ok\" = 1 ] && echo TEST_OK || echo TEST_FAIL
  '" 2>&1) || out="SSH_ERR"
  echo "$out" | tail -4
  if echo "$out" | grep -q TEST_OK; then
    echo "$name OK" | tee -a "$RESULTS"
    ok=$((ok+1))
  else
    echo "$name FAIL" | tee -a "$RESULTS"
    fail=$((fail+1))
  fi
  rm -f "/tmp/${name}-t.tar"
done
echo "==== TEST DONE ok=$ok fail=$fail ====" | tee -a "$RESULTS"
