#!/usr/bin/env bash
# Упаковать каждый packages/<name> → dist/<name>.tar и собрать packages.json
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export COPYFILE_DISABLE=1
rm -rf dist
mkdir -p dist

python3 - <<'PY'
import hashlib, json, os, subprocess
from pathlib import Path

root = Path(".")
pkgs_dir = root / "packages"
dist = root / "dist"
dist.mkdir(exist_ok=True)

# meta hints from existing fields / defaults
META = {
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
    # pack directory as top-level name/
    subprocess.check_call(["tar", "-C", str(pkgs_dir), "-cf", str(out), name])
    size = out.stat().st_size
    # md5 of tar
    h = hashlib.md5()
    with open(out, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    md5 = h.hexdigest()
    ver, cat, kind, dest, check, desc = META.get(
        name, ("0.0.0", "misc", "dir", f"/data/local/opt/{name}", f"/data/local/opt/{name}", name)
    )
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
        "bin": name if name != "sqlite" else "sqlite3",
        "dest": dest,
        "check": check,
        "md5": md5,
        "size": size,
    }
    if not dest:
        entry.pop("dest", None)
    packages.append(entry)
    print(f"packed {name}: {size/1024/1024:.1f} MB")

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
