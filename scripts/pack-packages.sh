#!/usr/bin/env bash
# Упаковать каждый packages/<name> → dist/<name>.tar и собрать packages.json.
# Пакеты из текущего индекса без исходников в packages/ не выпадают: запись
# переносится как есть, а её архив берётся из ветки pkg (с проверкой md5), чтобы
# push-pkg-branch.sh (force-push только dist/) не удалил его из pkg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/tar-flags.sh"
rm -rf dist
mkdir -p dist

python3 - <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path

root = Path(".")
pkgs_dir = root / "packages"
dist = root / "dist"
dist.mkdir(exist_ok=True)
tar_flags = os.environ.get("TAR_CREATE_FLAGS_STR", "").split()

def md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

index_path = root / "packages.json"
old_index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.is_file() else {}
old_pkgs = {p["name"]: p for p in old_index.get("packages", [])}
base_url = (old_index.get("base_url") or "https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg").rstrip("/")

# meta hints from existing fields / defaults
META = {
  "neofetch": ("7.1.0", "system", "dir", "/data/local/opt/neofetch", "/data/local/opt/neofetch/bin/neofetch", "Системная информация (bash)"),
  "zsh": ("5.9.2", "shell", "dir", "/data/local/opt/zsh", "/data/local/opt/zsh/zsh", "Z shell (static musl)"),
  "fastfetch": ("2.70.0", "system", "dir", "/data/local/opt/fastfetch", "/data/local/opt/fastfetch/fastfetch", "Системная информация"),
  "dropbear": ("2022.82", "net", "dir", "/data/dropbear", "/data/dropbear/dropbear", "SSH server"),
  "curl": ("8.14.1", "net", "dir", "/data/local/opt/curl", "/data/local/opt/curl/bin/curl", "HTTP клиент + CA"),
  "miniserve": ("0.29.0", "net", "dir", "/data/local/opt/miniserve", "/data/local/opt/miniserve/miniserve", "HTTP file server"),
  "btop": ("1.4.7", "system", "dir", "/data/local/opt/btop", "/data/local/opt/btop/bin/btop", "Мониторинг (tty)"),
  "ffmpeg": ("7.0.2", "media", "dir", "/data/local/opt/ffmpeg", "/data/local/opt/ffmpeg/ffmpeg", "Медиаконвертер"),
  "nano": ("8.0", "editors", "dir", "/data/local/opt/nano", "/data/local/opt/nano/bin/nano", "Текстовый редактор"),
  "iperf3": ("3.17.1", "net", "dir", "/data/local/opt/iperf3", "/data/local/opt/iperf3/bin/iperf3", "Bandwidth test"),
  "tcpdump": ("4.99.4", "net", "dir", "/data/local/opt/tcpdump", "/data/local/opt/tcpdump/bin/tcpdump", "Сниффер"),
  "nmap": ("7.95", "net", "dir", "/data/local/opt/nmap", "/data/local/opt/nmap/bin/nmap", "Сканер сети"),
  "openvpn": ("2.6.20", "vpn", "dir", "/data/local/opt/openvpn", "/data/local/opt/openvpn/bin/openvpn", "OpenVPN client/server"),
  "wireguard": ("1.0.0", "vpn", "dir", "/data/local/opt/wireguard", "/data/local/opt/wireguard/bin/wg", "WireGuard (userspace)"),
  "darkhttpd": ("1.16", "net", "dir", "/data/local/opt/darkhttpd", "/data/local/opt/darkhttpd/bin/darkhttpd", "Простой HTTP server"),
  "sqlite": ("3.45.3", "db", "dir", "/data/local/opt/sqlite", "/data/local/opt/sqlite/bin/sqlite3", "SQLite CLI"),
  "python3": ("3.12.13", "lang", "dir", "/data/local/opt/python3", "/data/local/opt/python3/bin/python3", "Python 3 (Alpine musl)"),
  "apkg": ("1.0.0", "system", "file", "", "/data/local/bin/apkg", "Пакетный менеджер Alice"),
}

packages = []
for name in sorted(os.listdir(pkgs_dir)):
    src = pkgs_dir / name
    if not src.is_dir() or name.startswith("."):
        continue
    asset = f"{name}.tar"
    out = dist / asset
    # pack directory as top-level name/ (без xattr macOS — см. scripts/tar-flags.sh)
    subprocess.check_call(["tar", *tar_flags, "-C", str(pkgs_dir), "-cf", str(out), name])
    size = out.stat().st_size
    md5 = md5_file(out)
    ver, cat, kind, dest, check, desc = META.get(
        name, ("0.0.0", "misc", "dir", f"/data/local/opt/{name}", f"/data/local/opt/{name}", name)
    )
    bin_name = name if name != "sqlite" else "sqlite3"
    # .apkg-meta from mk-alpine-pkg.sh overrides defaults
    meta_file = src / ".apkg-meta"
    if meta_file.is_file():
        kv = {}
        for line in meta_file.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                kv[k.strip()] = v.strip()
        ver = kv.get("version", ver)
        cat = kv.get("category", cat)
        kind = kv.get("kind", kind)
        dest = kv.get("dest", dest)
        check = kv.get("check", check)
        desc = kv.get("description", desc)
        bin_name = kv.get("bin", bin_name)
    # file packages that are single binary folders (zsh, ffmpeg, miniserve, fastfetch)
    if kind == "file":
        # tar still contains packages/name structure; install extracts and finds bin
        pass
    entry = {
        "name": name,
        "version": ver,
        "arch": "aarch64",
        "description": desc,
        "category": cat,
        "kind": kind,
        "asset": asset,
        "bin": bin_name,
        "dest": dest,
        "check": check,
        "md5": md5,
        "size": size,
    }
    if not dest:
        entry.pop("dest", None)
    packages.append(entry)
    print(f"packed {name}: {size/1024/1024:.1f} MB")

def fetch_from_pkg(asset, dst, want_md5):
    """Текущий архив из ветки pkg: сначала локальный origin/pkg, потом raw.
    True — есть и md5 совпал; False — архива нет; строка — md5 найденного архива."""
    other = False
    for cmd in (
        ["git", "cat-file", "blob", f"origin/pkg:{asset}"],
        ["curl", "-fsSL", "--retry", "3", f"{base_url}/{asset}"],
    ):
        r = subprocess.run(cmd, capture_output=True)
        if r.returncode != 0:
            continue
        h = hashlib.md5(r.stdout).hexdigest()
        if not want_md5 or h == want_md5:
            dst.write_bytes(r.stdout)
            return True
        other = h
    return other

built = {p["name"] for p in packages}
problems = []
for name, e in sorted(old_pkgs.items()):
    if name in built:
        continue
    asset = e.get("asset") or f"{name}.tar"
    got = fetch_from_pkg(asset, dist / asset, e.get("md5", ""))
    if got is True:
        print(f"kept   {name}: нет packages/{name} — {asset} взят из ветки pkg")
    elif got is False:
        print(f"WARN   {name}: нет ни packages/{name}, ни {asset} в ветке pkg — запись оставлена как есть")
    else:
        problems.append(f"{name}: у {asset} в ветке pkg md5 {got}, а в индексе {e.get('md5')}")
        continue
    packages.append(e)
if problems:
    sys.exit("ОШИБКА: индекс и ветка pkg разошлись, packages.json не записан.\n"
             "Поправь md5/size в индексе или пересобери пакет:\n  " + "\n  ".join(problems))
packages.sort(key=lambda p: p["name"])

index = {
    "name": "yandex-station-repo",
    "arch": "aarch64",
    "description": "Пакеты для Яндекс.Станции (Alice Panel / apkg)",
    "base_url": "https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg",
    "index_url": "https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/packages.json",
    "packages": packages,
}
(root / "packages.json").write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"wrote packages.json ({len(packages)} pkgs)")
PY

ls -lh dist | head -40
