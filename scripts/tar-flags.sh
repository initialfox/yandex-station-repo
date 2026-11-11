# shellcheck shell=bash
# Подключается из скриптов упаковки: . "$ROOT/scripts/tar-flags.sh"
#
# bsdtar (macOS) пишет в pax-заголовок КАЖДОГО файла xattr com.apple.provenance
# (LIBARCHIVE.xattr.* / SCHILY.xattr.*). GNU tar на это печатает
# «Ignoring unknown extended header keyword», toybox/busybox tar на станции
# может ругаться или вести себя криво. COPYFILE_DISABLE=1 убирает только
# AppleDouble-файлы ._*, а xattr — нет: нужны явные --no-xattrs/--no-mac-metadata.
export COPYFILE_DISABLE=1
TAR_CREATE_FLAGS=()
if tar --version 2>/dev/null | grep -qi bsdtar; then
  TAR_CREATE_FLAGS=(--no-xattrs --no-mac-metadata --no-acls --no-fflags)
fi
# строкой — для python-части pack-packages.sh
export TAR_CREATE_FLAGS_STR="${TAR_CREATE_FLAGS[*]-}"

# tar_c <аргументы tar…> — создать архив без xattr/ACL/fflags.
# Запись ${a[@]+"${a[@]}"} — чтобы пустой массив не падал в bash 3.2 (macOS) с set -u.
tar_c() {
  tar ${TAR_CREATE_FLAGS[@]+"${TAR_CREATE_FLAGS[@]}"} "$@"
}
