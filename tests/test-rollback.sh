#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/debian-bookworm-to-trixie.sh"

((EUID == 0)) || {
  echo "rollback test must run as root inside a disposable container" >&2
  exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BACKUP_DIR="$TMP/backup"
mkdir -p "$BACKUP_DIR/apt"

cp -a /etc/apt/sources.list "$BACKUP_DIR/apt/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/apt/" 2>/dev/null || true

snapshot_sources() {
  local out=$1
  {
    if [[ -f /etc/apt/sources.list ]]; then
      printf '%s  %s\n' "$(sha256sum /etc/apt/sources.list | awk '{print $1}')" /etc/apt/sources.list
    fi
    find /etc/apt/sources.list.d -maxdepth 1 -type f -print0 2>/dev/null \
      | sort -z \
      | xargs -0 -r sha256sum
  } > "$out"
}

snapshot_sources "$TMP/before.sha256"

mkdir -p /etc/apt/sources.list.d
printf 'deb http://invalid.example.invalid/debian trixie main\n' > /etc/apt/sources.list.d/rollback-corruption.list
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  printf '\n# destructive rollback fixture\n' >> /etc/apt/sources.list.d/debian.sources
elif [[ -f /etc/apt/sources.list ]]; then
  printf '\n# destructive rollback fixture\n' >> /etc/apt/sources.list
fi

restore_sources
snapshot_sources "$TMP/after.sha256"

diff -u "$TMP/before.sha256" "$TMP/after.sha256"
test ! -e /etc/apt/sources.list.d/rollback-corruption.list

echo "[rollback] APT source configuration restored byte-for-byte"
