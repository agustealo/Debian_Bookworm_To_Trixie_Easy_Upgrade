#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${DEBIAN_BOOKWORM_IMAGE:-debian:12}

command -v docker >/dev/null 2>&1 || {
  echo "docker is required for the disposable integration test" >&2
  exit 1
}

echo "[integration] pulling $IMAGE"
docker pull "$IMAGE"

echo "[integration] running real Bookworm -> Trixie package transition"
docker run --rm \
  --name trixie-upgrade-integration \
  --volume "$ROOT_DIR:/workspace:ro" \
  "$IMAGE" \
  bash -lc '
    set -Eeuo pipefail
    cp /workspace/debian-bookworm-to-trixie.sh /root/debian-bookworm-to-trixie.sh
    chmod 0755 /root/debian-bookworm-to-trixie.sh

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates

    /root/debian-bookworm-to-trixie.sh \
      --non-interactive \
      --yes \
      --no-reboot \
      --backup-dir /var/backups/trixie-integration

    . /etc/os-release
    test "$ID" = debian
    test "$VERSION_ID" = 13
    test "$VERSION_CODENAME" = trixie
    dpkg --audit
    apt-get check

    if grep -RhsE "^[[:space:]]*(deb|deb-src).*bookworm([[:space:]-]|$)" \
      /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
      | grep -v "disabled-by-trixie-upgrade" >/dev/null; then
      echo "active Bookworm repository remained after integration upgrade" >&2
      exit 1
    fi

    test -s /var/backups/trixie-integration/*/upgrade.log
    echo "[integration] verified Debian 13 Trixie and healthy package state"
  '
