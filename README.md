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

### Важно: buildroot = часто read-only

На **не-Android** (gen2+ / buildroot) rootfs часто смонтирован **только для чтения**. Перед установкой `apkg` и пакетов сделай rw:

```sh
mount -o remount,rw /
# при необходимости:
mount -o remount,rw /usr
mount -o remount,rw /usr/local
mount -o remount,rw /opt
```

`install.sh` и `install-adb.sh` на buildroot пытаются сделать remount сами; если всё равно `Read-only file system` — выполни команды выше вручную (под root).

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

Скрипт качает `apkg`, делает `adb push`, на buildroot — remount rw, ставит в `/data/local/bin` (Android) или `/usr/local/bin` (buildroot), затем `apkg update`.

### SSH (с компа)

```sh
./scripts/install-ssh.sh root@192.168.1.50
./scripts/install-ssh.sh -p 2222 root@host
```

На удалённой стороне — `install.sh` (Android / buildroot + remount rw).

### SSH / на станции одной строкой

Если DNS на колонке живой:

```sh
curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
```

Если `Could not resolve host` (часто на Station 1, DNS → `::1:53`) — с `--resolve`:

```sh
curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133   https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
```

Или надёжнее с компа через ADB push: `./scripts/install-adb.sh`

```sh
ssh root@IP 'curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133 https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh'
```

Buildroot + read-only:

```sh
ssh root@IP 'mount -o remount,rw /; curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133 https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh'
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

Musl-пакеты: `opt/<имя>` + обёртка в bindir с абсолютным `DIR`.

## Обновить ветку пакетов

```sh
./scripts/pack-packages.sh
./scripts/push-pkg-branch.sh
```
