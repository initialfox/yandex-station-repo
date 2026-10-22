#!/bin/sh
# С компа: поставить apkg по SSH.
#   ./scripts/install-ssh.sh root@192.168.1.50
#   ./scripts/install-ssh.sh -p 2222 root@host
set -e

APKG_URL="${APKG_URL:-https://raw.githubusercontent.com/initialfox/yandex-station-repo/pkg/apkg}"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/initialfox/yandex-station-repo/main/install.sh}"
SSH_OPTS=""
HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p) SSH_OPTS="$SSH_OPTS -p $2"; shift 2 ;;
    -i) SSH_OPTS="$SSH_OPTS -i $2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [-p port] [-i key] user@host"
      exit 0
      ;;
    *) HOST="$1"; shift ;;
  esac
done

if [ -z "$HOST" ]; then
  echo "Usage: $0 [-p port] [-i key] user@host" >&2
  exit 1
fi

echo "→ SSH $HOST (remote install.sh)"
# shellcheck disable=SC2086
ssh -o StrictHostKeyChecking=accept-new $SSH_OPTS "$HOST" \
  "curl -kfsSL '$INSTALL_URL' | sh"

echo
echo "✓ готово. На станции: apkg install nano curl"
