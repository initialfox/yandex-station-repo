#!/system/bin/sh
# Смоук-тест пакета на станции: распаковать архив и запустить <name>-run с флагами
# версии. Его заливают на станцию и запускают one-pkg.sh и batch-*.sh:
#   sh apkg-smoke.sh <tar> <name> <bin>
# Печатает начало вывода программы, причину и последней строкой TEST_OK или
# TEST_FAIL (exit 0 / 1). Архив и распаковку за собой удаляет.
#
# Однозначная ошибка (сообщение загрузчика или интерпретатора, exit 126/127,
# падение по сигналу) сразу даёт TEST_FAIL, и никакой «похожий на версию» вывод
# её не перекрывает. Раньше шаблон [0-9]{2,} находил «64» в
# «ld-musl-aarch64.so.1: … Not a valid dynamic program», и сломанный parallel
# проходил тест.

TAR=$1
NAME=$2
BIN=$3
export ANDROID_DATA=/data ANDROID_ROOT=/system

WORK="${TAR%/*}/apkg-smoke-$NAME"
OUT="$WORK/.out"

# загрузчик musl/bionic, perl, python, обёртка пакета («<name>: missing <bin>»)
FAIL_RE='Error loading shared library|cannot open shared object|Not a valid dynamic program|Error relocating|cannot load |Dynamic Program Loader|CANNOT LINK EXECUTABLE|Exec format error|Can.t locate |Can.t load |BEGIN failed--compilation aborted|ModuleNotFoundError|Fatal Python error|: missing /'
# флаг не понят — пробуем следующий
OPT_RE='unrecognized option|unrecognised option|invalid option|unknown option|illegal option'
# похоже на вывод версии или справки
OK_RE='[0-9]+\.[0-9]+|usage|syntax|copyright|comes with|socat'

finish() {
  if [ -f "$OUT" ]; then
    dd if="$OUT" bs=240 count=1 2>/dev/null
    echo
  fi
  echo "reason: $2"
  rm -rf "$WORK" "$TAR"
  echo "TEST_$1"
  if [ "$1" = OK ]; then exit 0; fi
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK" || finish FAIL "не создать $WORK"
tar xf "$TAR" -C "$WORK" || finish FAIL "не распаковался $TAR"
RUN="$WORK/$NAME/$NAME-run"
[ -f "$RUN" ] || finish FAIL "в архиве нет $NAME/$NAME-run"

TO=
if command -v timeout >/dev/null 2>&1; then TO="timeout 20"; fi

for flg in -V -v --version -h; do
  $TO "$RUN" $flg </dev/null >"$OUT" 2>&1
  rc=$?
  if grep -qiE "$FAIL_RE" "$OUT"; then
    finish FAIL "ошибка загрузчика/интерпретатора на $flg (exit $rc)"
  fi
  case $rc in
    126|127) finish FAIL "exit $rc на $flg: не запускается" ;;
    13[2-9]) finish FAIL "exit $rc на $flg: упал по сигналу" ;;
    124) if [ -n "$TO" ]; then finish OK "на $flg работает дольше 20 с"; fi ;;
  esac
  if grep -qiE "$OPT_RE" "$OUT"; then continue; fi
  if grep -qiE "$OK_RE" "$OUT"; then finish OK "ответ на $flg"; fi
done

# Ни один флаг не дал узнаваемого вывода, но и ошибок запуска не было:
# так ведут себя TUI-программы (htop, screen). Считаем рабочим, как и раньше.
if [ -x "$WORK/$NAME/bin/$BIN" ]; then
  finish OK "версию не распознал, но запуск без ошибок"
fi
finish FAIL "нет исполняемого $NAME/bin/$BIN"
