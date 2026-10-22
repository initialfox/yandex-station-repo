# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

Две платформы (один набор пакетов):

| Версия | ОС | Куда ставит |
|--------|-----|-------------|
| **Android** | bionic (`/system/bin/linker*`) | `/data/local/bin`, `/data/local/opt` |
| **buildroot** | обычный Linux | `/usr/local/bin` / `/opt` (без `/sdcard`) |

Смотри фактические пути: `apkg paths` → `flavor android` или `flavor buildroot`.

| Что | URL |
|-----|-----|
| индекс | `raw.../main/packages.json` |
| пакеты | ветка **`pkg`** → `raw.../pkg/<name>.tar` |
| `apkg` | `raw.../pkg/apkg` |

В Releases — только бинарь `apkg`. У curl на колонке нужен **`-k`** (нет CA).

### Важно: buildroot = часто read-only

На **buildroot** rootfs часто смонтирован **только для чтения**. Перед установкой `apkg` и пакетов:

```sh
mount -o remount,rw /
```

`install.sh` и `install-adb.sh` на buildroot делают remount сами; если всё равно `Read-only file system` — выполни вручную (root).

---

## Установка скриптом

### ADB (с компа, push)

```sh
git clone https://github.com/initialfox/yandex-station-repo.git
cd yandex-station-repo
./scripts/install-adb.sh
./scripts/install-adb.sh -s SERIAL
```

Скрипт качает `apkg`, делает `adb push`, на **buildroot** — remount rw, ставит в `/data/local/bin` (**Android**) или `/usr/local/bin` (**buildroot**), затем `apkg update`.

### SSH (с компа)

```sh
./scripts/install-ssh.sh root@192.168.1.50
./scripts/install-ssh.sh -p 2222 root@host
```

На станции — `install.sh` (определяет **Android** / **buildroot**).

### SSH / на станции одной строкой

Если DNS живой:

```sh
curl -kfsSL https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
```

Если `Could not resolve host` (часто на **Android**, DNS → `::1:53`) — с `--resolve`:

```sh
curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133 \
  https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh
```

Надёжнее с компа: `./scripts/install-adb.sh`

```sh
ssh root@IP 'curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133 https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh'
```

**buildroot** + read-only:

```sh
ssh root@IP 'mount -o remount,rw /; curl -kfsSL --resolve raw.githubusercontent.com:443:185.199.108.133 https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh | sh'
```

---

## Команды apkg

| Команда | Зачем |
|---------|--------|
| `apkg paths` | `flavor` = `android` или `buildroot` |
| `apkg update` | обновить индекс |
| `apkg list` / `apkg search vpn` | список / поиск |
| `apkg install nano` | поставить |
| `apkg remove nano` | убрать |
| `apkg upgrade` | обновить установленные |

Переменные: `APKG_BINDIR` `APKG_OPT` `APKG_CACHE` `APKG_STATE` `APKG_INDEX` `APKG_BASE`

Musl-пакеты: `opt/<имя>` + обёртка в bindir с абсолютным `DIR`.

---

## Как добавить пакет

Цель: **aarch64**, желательно **musl** (Alpine) или static. Один пакет должен работать и на **Android**, и на **buildroot**.

### 1. Структура каталога

```
packages/<имя>/
  bin/<бинарь>          # или просто <бинарь> в корне пакета
  lib/                  # musl: ld-musl-aarch64.so.1 + все .so
                        # + SONAME-symlink'и (libfoo.so.1 → libfoo.so.1.2.3)
  <имя>-run             # обёртка #!/bin/sh
```

Пример обёртки (`packages/nano/nano-run`):

```sh
#!/bin/sh
DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
export LD_LIBRARY_PATH="$DIR/lib:${LD_LIBRARY_PATH:-}"
exec "$DIR/lib/ld-musl-aarch64.so.1" "$DIR/bin/nano" "$@"
```

Для static-бинаря достаточно одного файла в `packages/<имя>/<имя>` (`kind: file`).

### 2. META в pack-скрипте

В `scripts/pack-packages.sh` добавь строку в `META`:

```python
"mytool": ("1.2.3", "net", "dir", "/data/local/opt/mytool", "/data/local/opt/mytool/bin/mytool", "Описание"),
# name: (version, category, kind, dest, check, description)
# kind: "dir" (бандл) | "file" (один бинарь)
```

`dest`/`check` пиши под Android-пути — на buildroot `apkg` сам ремапит в `opt`/`bindir`.

### 3. Собрать и залить

```sh
./scripts/pack-packages.sh          # → dist/*.tar + packages.json
./scripts/push-pkg-branch.sh        # ветка pkg (raw) — откуда качает станция
git add packages packages.json scripts/pack-packages.sh
git commit -m "add mytool" && git push origin main
```

Проверка на колонке: `apkg update && apkg install mytool && mytool --version`.

### Чеклист

- [ ] aarch64, не x86
- [ ] musl-бандл: в `lib/` есть `ld-musl-aarch64.so.1` и все зависимости
- [ ] SONAME-symlink'и на месте (`liblzo2.so.2` → `liblzo2.so.2.0.0`, …)
- [ ] есть `<имя>-run` с `#!/bin/sh` (не bash)
- [ ] не хардкодить `/data/local` внутри обёртки — только `DIR=...`
- [ ] прогнать на Android и/или buildroot

Готовый Alpine-бандл можно собрать так: `./scripts/build-alpine-bundle.sh <apk-пакет>`.

---

## Хочешь добавить пакет в репу?

Напиши в Telegram в личку: **[@initialfox](https://t.me/initialfox)**  
(архив / `tar` / ссылка + коротко что за утилита). Могу спокойно залить бинарники в репозиторий.

## Обновить ветку пакетов (мейнтейнер)

```sh
./scripts/pack-packages.sh
./scripts/push-pkg-branch.sh
```
