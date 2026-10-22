# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

- **Station 1 (Android):** `/data/local/bin`, `/data/local/opt`
- **gen2+ (buildroot):** `/usr/local/bin` / `/opt` — без `/sdcard`

Один набор пакетов на обе платформы. Пути: `apkg paths`.

| Что | URL |
|-----|-----|
| индекс | `raw.../main/packages.json` |
| пакеты | ветка **`pkg`** → `raw.../pkg/<name>.tar` |
| `apkg` | `raw.../pkg/apkg` |

В Releases — только бинарь `apkg`. У curl на колонке нужен **`-k`** (нет CA).

---

## Установка скриптом

### ADB (с компа, push)

```sh
git clone https://github.com/initialfox/yandex-station-repo.git
cd yandex-station-repo
./scripts/install-adb.sh
# несколько устройств:
./scripts/install-adb.sh -s SERIAL
```

Скрипт сам качает `apkg`, делает `adb push`, ставит в `/data/local/bin` (Android) или `/usr/local/bin` (buildroot) и запускает `apkg update`.

### SSH (с компа)

```sh
./scripts/install-ssh.sh root@192.168.1.50
./scripts/install-ssh.sh -p 2222 root@host
```

На удалённой стороне выполняется `install.sh` (определяет Android / buildroot).

### SSH одной строкой (на станции или через ssh)

```sh
curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
```

Или:

```sh
ssh root@IP 'curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh'
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

Musl-пакеты: `opt/<имя>` + symlink в bindir. Обёртки `#!/bin/sh` + `DIR=$(dirname "$0")`.

## Обновить ветку пакетов

```sh
./scripts/pack-packages.sh
./scripts/push-pkg-branch.sh
```
