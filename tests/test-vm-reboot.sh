#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=${WORK_DIR:-"$(mktemp -d)"}
VM_IMAGE=${VM_IMAGE:-"$WORK_DIR/bookworm.qcow2"}
SEED_IMAGE=${SEED_IMAGE:-"$WORK_DIR/seed.img"}
SSH_KEY=${SSH_KEY:-"$WORK_DIR/id_ed25519"}
SERIAL_LOG=${SERIAL_LOG:-"$WORK_DIR/serial.log"}
QEMU_PID_FILE=${QEMU_PID_FILE:-"$WORK_DIR/qemu.pid"}
SSH_PORT=${SSH_PORT:-2222}
BOOKWORM_IMAGE_URL=${BOOKWORM_IMAGE_URL:-https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2}
KEEP_VM_ARTIFACTS=${KEEP_VM_ARTIFACTS:-0}

cleanup() {
    if [[ -f "$QEMU_PID_FILE" ]]; then
        local pid
        pid=$(cat "$QEMU_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
    if [[ $KEEP_VM_ARTIFACTS != 1 ]]; then
        rm -rf "$WORK_DIR"
    else
        printf '[vm] artifacts retained at %s\n' "$WORK_DIR"
    fi
}
trap cleanup EXIT

require() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

for command_name in curl qemu-img qemu-system-x86_64 cloud-localds ssh ssh-keygen scp; do
    require "$command_name"
done

mkdir -p "$WORK_DIR"
ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"

printf '[vm] downloading Debian 12 generic cloud image\n'
curl --fail --location --retry 3 --output "$VM_IMAGE" "$BOOKWORM_IMAGE_URL"
qemu-img resize "$VM_IMAGE" 12G >/dev/null

cat > "$WORK_DIR/meta-data" <<'EOF'
instance-id: trixie-safety-7
local-hostname: trixie-safety-7
EOF

cat > "$WORK_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ci
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$SSH_KEY.pub")
ssh_pwauth: false
package_update: false
runcmd:
  - [ sh, -c, 'touch /var/tmp/cloud-init-ready' ]
EOF

cloud-localds "$SEED_IMAGE" "$WORK_DIR/user-data" "$WORK_DIR/meta-data"

QEMU_ACCEL=tcg
QEMU_CPU=max
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    QEMU_ACCEL=kvm
    QEMU_CPU=host
fi
printf '[vm] booting Bookworm VM under QEMU/%s\n' "$QEMU_ACCEL"
qemu-system-x86_64 \
    -machine "accel=$QEMU_ACCEL" \
    -cpu "$QEMU_CPU" \
    -smp 2 \
    -m 3072 \
    -drive "file=$VM_IMAGE,if=virtio,format=qcow2" \
    -drive "file=$SEED_IMAGE,if=virtio,format=raw" \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -daemonize \
    -pidfile "$QEMU_PID_FILE"

SSH_ARGS=(
    -i "$SSH_KEY"
    -p "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)
SCP_ARGS=(
    -i "$SSH_KEY"
    -P "$SSH_PORT"
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)

wait_for_ssh() {
    local attempts=${1:-120}
    local attempt
    for ((attempt=1; attempt<=attempts; attempt++)); do
        if ssh "${SSH_ARGS[@]}" ci@127.0.0.1 'true' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    printf '[vm] SSH did not become ready\n' >&2
    tail -n 200 "$SERIAL_LOG" >&2 || true
    return 1
}

wait_for_ssh 120
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 'while [ ! -e /var/tmp/cloud-init-ready ]; do sleep 2; done'

printf '[vm] proving initial Bookworm identity\n'
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 '. /etc/os-release; test "$ID" = debian; test "$VERSION_ID" = 12; test "$VERSION_CODENAME" = bookworm'

cat > "$WORK_DIR/prepare-cloud-sources.sh" <<'EOF'
#!/bin/sh
set -eu
source_file=/etc/apt/sources.list.d/debian.sources
test -f "$source_file"
grep -q 'mirror+file:' "$source_file"
awk '
/^Suites:/ {
    line=$1
    for (i=2; i<=NF; i++) {
        if ($i != "bookworm-backports" && $i != "bookworm-backports-sloppy") {
            line=line " " $i
        }
    }
    print line
    next
}
{ print }
' "$source_file" > "$source_file.tmp"
cat "$source_file.tmp" > "$source_file"
rm -f "$source_file.tmp"
grep -q 'mirror+file:' "$source_file"
! grep -Eq '(^|[[:space:]])bookworm-backports(-sloppy)?([[:space:]]|$)' "$source_file"
EOF
chmod +x "$WORK_DIR/prepare-cloud-sources.sh"

printf '[vm] preserving native Debian cloud mirror transport and removing blocked backports suites\n'
scp "${SCP_ARGS[@]}" "$WORK_DIR/prepare-cloud-sources.sh" ci@127.0.0.1:/tmp/prepare-cloud-sources.sh
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 'sudo /bin/sh /tmp/prepare-cloud-sources.sh'

scp "${SCP_ARGS[@]}" "$ROOT_DIR/debian-bookworm-to-trixie.sh" ci@127.0.0.1:/tmp/debian-bookworm-to-trixie.sh

printf '[vm] executing production upgrader\n'
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 'sudo chmod +x /tmp/debian-bookworm-to-trixie.sh && sudo /tmp/debian-bookworm-to-trixie.sh --non-interactive --yes --no-reboot --backup-dir /var/backups/trixie-vm'

printf '[vm] rebooting upgraded VM\n'
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 'sudo systemctl reboot' || true
sleep 10
wait_for_ssh 180

printf '[vm] verifying post-reboot Trixie state\n'
ssh "${SSH_ARGS[@]}" ci@127.0.0.1 '
set -eu
. /etc/os-release
test "$ID" = debian
test "$VERSION_ID" = 13
test "$VERSION_CODENAME" = trixie
dpkg --audit | grep -qv .
sudo apt-get check >/dev/null
dpkg-query -W -f="${Status}\n" linux-image-amd64 | grep -q "install ok installed"
uname -r | grep -Eq "^[0-9]+\\.[0-9]+.*-amd64$"
test -d /var/backups/trixie-vm
! grep -RhsE "^[[:space:]]*(deb|deb-src).*bookworm([[:space:]-]|$)" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -v disabled-by-trixie-upgrade | grep -q .
! grep -RhsE "^[[:space:]]*Suites:[[:space:]].*bookworm([[:space:]-]|$)" /etc/apt/sources.list.d 2>/dev/null | grep -q .
failed=$(systemctl --failed --no-legend --plain 2>/dev/null || true)
if [ -n "$failed" ]; then
  printf "%s\\n" "$failed" >&2
  exit 1
fi
'

printf 'PASS: VM upgraded native cloud sources, rebooted, and verified on Debian 13 Trixie\n'
