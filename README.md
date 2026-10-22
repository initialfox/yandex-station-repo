# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

Работает на:
- **Station 1 (Android):** `/data/local/bin`, `/data/local/opt`, кэш `/sdcard` или `/data/local/tmp`
- **gen2+ (buildroot):** `/usr/local/bin` / `/opt`, кэш `/tmp` / `/var/cache` — без `/sdcard` и `/system/bin/sh`

Смотри пути: `apkg paths`

## Откуда качается

| Что | URL |
|-----|-----|
| индекс | `raw.githubusercontent.com/.../main/packages.json` |
| пакеты `*.tar` | ветка **`pkg`** → `raw.githubusercontent.com/.../pkg/<name>.tar` |
| бинарь `apkg` | Release **или** тот же `pkg/apkg` |

В Releases кладём только `apkg`, не все пакеты.

## Быстрый старт

```sh
# android (-k обязателен: нет CA)
mkdir -p /data/local/bin
curl -kfsSL -o /data/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /data/local/bin/apkg

# buildroot
mkdir -p /usr/local/bin
curl -kfsSL -o /usr/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /usr/local/bin/apkg

apkg paths
apkg update && apkg list
apkg install nano curl
```

Musl-пакеты: `opt/<имя>` + symlink в bindir. Обёртки `#!/bin/sh` + `DIR=$(dirname "$0")`.

Переменные: `APKG_BINDIR` `APKG_OPT` `APKG_CACHE` `APKG_STATE` `APKG_INDEX` `APKG_BASE`

Обновить ветку пакетов после `pack-packages.sh`:

```sh
./scripts/push-pkg-branch.sh
```
