#!/usr/bin/env bash
# Прогнать packages/<name> на станции: push → run → удалить
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/tar-flags.sh"
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

# проверка на станции — scripts/station-smoke.sh (та же, что в one-pkg.sh)
ssh_st "cat > /data/local/tmp/apkg-smoke.sh" < scripts/station-smoke.sh || { echo "не залить station-smoke.sh на $ST"; exit 1; }

ok=0; fail=0
for name in "${NAMES[@]}"; do
  bin=$(sed -n 's/^bin=//p' "packages/$name/.apkg-meta")
  [[ -n "$bin" ]] || bin=$name
  echo "######## TEST $name ($bin) ########"
  tar_c -C packages -cf "/tmp/${name}-t.tar" "$name"
  if ! ssh_st "cat > /data/local/tmp/${name}-t.tar" < "/tmp/${name}-t.tar"; then
    echo "$name PUSH_FAIL" | tee -a "$RESULTS"
    fail=$((fail+1))
    continue
  fi
  out=$(ssh_st "/system/bin/sh /data/local/tmp/apkg-smoke.sh /data/local/tmp/${name}-t.tar $name $bin" 2>&1) || true
  echo "$out" | tail -4
  if echo "$out" | grep -qx TEST_OK; then
    echo "$name OK" | tee -a "$RESULTS"
    ok=$((ok+1))
  else
    echo "$name FAIL" | tee -a "$RESULTS"
    fail=$((fail+1))
  fi
  rm -f "/tmp/${name}-t.tar"
done
echo "==== TEST DONE ok=$ok fail=$fail ====" | tee -a "$RESULTS"
