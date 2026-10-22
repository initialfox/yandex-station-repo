# yandex-station-repo

Пакеты для Яндекс.Станций + менеджер **`apkg`** (один статический бинарь aarch64).

## Быстрый старт

```sh
curl -kfsSL -o /data/local/bin/apkg \
  https://github.com/initialfox/yandex-station-repo/releases/latest/download/apkg
chmod 755 /data/local/bin/apkg

apkg update
apkg list
apkg install nano curl
```

Musl-пакеты (`nano`, `nmap`, …) ставятся в `/data/local/opt/<имя>` с `lib/` и обёрткой → `/data/local/bin/<имя>`.  
Голый ELF без loader = `not found`.

## Связь с панелью

Alice Panel ставит пакеты через этот репозиторий (`packages.json` + релизы).

- индекс: `packages.json` (main / jsDelivr)
- ассеты: `releases/latest/download/<name>.tar` и `apkg`
