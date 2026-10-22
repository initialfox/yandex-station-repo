# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

Работает на:
- **Station 1 (Android):** `/data/local/bin`, `/data/local/opt`
- **gen2+ (buildroot):** `/usr/local/bin` / `/opt` — без `/sdcard` и `/system/bin/sh`

Один набор пакетов на обе платформы. Пути смотри: `apkg paths`.

## Откуда качается

| Что | URL |
|-----|-----|
| индекс | `raw.githubusercontent.com/.../main/packages.json` |
| пакеты `*.tar` | ветка **`pkg`** → `raw.githubusercontent.com/.../pkg/<name>.tar` |
| бинарь `apkg` | та же ветка `pkg/apkg` (или Release) |

В Releases — только `apkg`, не все пакеты. `-k` у curl обязателен (на колонках часто нет CA).

---

## Android (Station 1) — ADB

```sh
adb shell su 0 sh -c '
mkdir -p /data/local/bin /data/local/tmp
curl -kfsSL -o /data/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /data/local/bin/apkg
export PATH=/data/local/bin:$PATH
apkg paths
apkg update
apkg install nano curl
'
```

Если на колонке нет `curl` — с компа:

```sh
curl -kfsSL -o /tmp/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
adb push /tmp/apkg /data/local/tmp/apkg
adb shell su 0 sh -c '
mkdir -p /data/local/bin
cp /data/local/tmp/apkg /data/local/bin/apkg
chmod 755 /data/local/bin/apkg
export PATH=/data/local/bin:$PATH
apkg update && apkg install nano
'
```

## Android — SSH

```sh
ssh root@IP-СТАНЦИИ

mkdir -p /data/local/bin
curl -kfsSL -o /data/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /data/local/bin/apkg
export PATH=/data/local/bin:$PATH

apkg paths          # flavor android
apkg update
apkg list
apkg install nano curl btop
```

---

## Linux / buildroot (gen2+) — ADB

```sh
adb shell '
mkdir -p /usr/local/bin /tmp
curl -kfsSL -o /usr/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /usr/local/bin/apkg
export PATH=/usr/local/bin:$PATH
apkg paths
apkg update
apkg install nano curl
'
```

Без `curl` на устройстве:

```sh
curl -kfsSL -o /tmp/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
adb push /tmp/apkg /tmp/apkg
adb shell 'mkdir -p /usr/local/bin; cp /tmp/apkg /usr/local/bin/apkg; chmod 755 /usr/local/bin/apkg'
```

## Linux / buildroot — SSH

```sh
ssh root@IP-СТАНЦИИ

mkdir -p /usr/local/bin
curl -kfsSL -o /usr/local/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /usr/local/bin/apkg
export PATH=/usr/local/bin:$PATH

apkg paths          # flavor buildroot
apkg update
apkg list
apkg install nano curl
```

Если `/usr/local/bin` недоступен:

```sh
export APKG_BINDIR=/opt/bin APKG_OPT=/opt
mkdir -p /opt/bin
curl -kfsSL -o /opt/bin/apkg \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg
chmod 755 /opt/bin/apkg
export PATH=/opt/bin:$PATH
```

---

## Команды apkg

| Команда | Зачем |
|---------|--------|
| `apkg paths` | куда ставит (android / buildroot) |
| `apkg update` | обновить индекс |
| `apkg list` / `apkg search vpn` | список / поиск |
| `apkg install nano` | поставить |
| `apkg remove nano` | убрать |
| `apkg upgrade` | обновить установленные |

Переменные: `APKG_BINDIR` `APKG_OPT` `APKG_CACHE` `APKG_STATE` `APKG_INDEX` `APKG_BASE`

Musl-пакеты: `opt/<имя>` + symlink в bindir. Обёртки `#!/bin/sh` + `DIR=$(dirname "$0")`. Голый ELF = `not found`.

## Обновить ветку пакетов

После `./scripts/pack-packages.sh`:

```sh
./scripts/push-pkg-branch.sh
```
