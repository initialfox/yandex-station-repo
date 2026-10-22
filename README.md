# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

Работает на:
- **Station 1 (Android):** `/data/local/bin`, `/data/local/opt`, кэш `/sdcard` или `/data/local/tmp`
- **gen2+ (buildroot):** `/usr/local/bin` / `/opt`, кэш `/tmp` / `/var/cache` — без `/sdcard` и `/system/bin/sh`

Смотри пути: `apkg paths`

## Быстрый старт

```sh
# android
mkdir -p /data/local/bin
curl -kfsSL -o /data/local/bin/apkg \
  https://github.com/initialfox/yandex-station-repo/releases/latest/download/apkg
chmod 755 /data/local/bin/apkg

# buildroot
mkdir -p /usr/local/bin
curl -kfsSL -o /usr/local/bin/apkg \
  https://github.com/initialfox/yandex-station-repo/releases/latest/download/apkg
chmod 755 /usr/local/bin/apkg

apkg paths
apkg update && apkg list
apkg install nano curl
```

Musl-пакеты ставятся в `opt/<имя>` + symlink в bindir.  
Обёртки: `#!/bin/sh` и `DIR=$(dirname "$0")`. Голый ELF = `not found`.

Переменные: `APKG_BINDIR` `APKG_OPT` `APKG_CACHE` `APKG_STATE` `APKG_INDEX` `APKG_BASE`
