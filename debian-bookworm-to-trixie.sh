#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="1.0.0"
TARGET_CODENAME="trixie"
TARGET_VERSION_ID="13"
SOURCE_CODENAME="bookworm"
DEFAULT_BACKUP_ROOT="/var/backups/debian-bookworm-to-trixie"
BACKUP_ROOT="${BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
BACKUP_DIR=""
LOG_FILE=""
DRY_RUN=0
NON_INTERACTIVE=0
NO_REBOOT=0
ALLOW_THIRD_PARTY=0
ASSUME_YES=0
PHASE="startup"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warning() { printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
die() { log_error "$*"; exit 1; }

on_error() {
    local status=$?
    local line=${BASH_LINENO[0]:-unknown}
    local command=${BASH_COMMAND:-unknown}
    log_error "Failure during phase '$PHASE' (exit $status, line $line): $command"
    [[ -n "$LOG_FILE" ]] && log_error "Review log: $LOG_FILE"
    exit "$status"
}
trap on_error ERR

usage() {
    cat <<USAGE
Usage: sudo ./debian-bookworm-to-trixie.sh [options]

Options:
  --dry-run             Validate and preview without changing the system
  --non-interactive     Do not prompt; fail closed on unsafe conditions
  --yes                 Assume yes for safe confirmation prompts
  --backup-dir PATH     Backup root directory (default: $DEFAULT_BACKUP_ROOT)
  --allow-third-party   Keep enabled third-party APT sources (not recommended)
  --no-reboot           Never offer to reboot at the end
  -h, --help            Show this help
USAGE
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --non-interactive) NON_INTERACTIVE=1 ;;
            --yes) ASSUME_YES=1 ;;
            --allow-third-party) ALLOW_THIRD_PARTY=1 ;;
            --no-reboot) NO_REBOOT=1 ;;
            --backup-dir) shift; (($#)) || die "--backup-dir requires a path"; BACKUP_ROOT=$1 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
        shift
    done
}

confirm() {
    local prompt=$1 reply
    ((ASSUME_YES)) && return 0
    ((NON_INTERACTIVE)) && return 1
    read -r -p "$prompt [y/N]: " reply
    [[ $reply =~ ^[Yy]$ ]]
}

run() {
    if ((DRY_RUN)); then
        printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'
        return 0
    fi
    "$@"
}

require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

load_os_release() {
    [[ -r /etc/os-release ]] || die "/etc/os-release is missing"
    # shellcheck disable=SC1091
    . /etc/os-release
}

validate_platform() {
    PHASE="platform validation"
    ((EUID == 0)) || die "Run this script as root (sudo)."
    load_os_release
    [[ ${ID:-} == "debian" ]] || die "This upgrader supports Debian only (detected ID=${ID:-unknown})."
    [[ ${VERSION_ID:-} == "12" ]] || die "Expected Debian 12 Bookworm (detected VERSION_ID=${VERSION_ID:-unknown})."
    [[ ${VERSION_CODENAME:-} == "$SOURCE_CODENAME" ]] || die "Expected codename $SOURCE_CODENAME (detected ${VERSION_CODENAME:-unknown})."
    case "$(dpkg --print-architecture)" in
        amd64|arm64|armhf|i386|ppc64el|s390x) ;;
        *) log_warning "Architecture $(dpkg --print-architecture) is unusual; verify Debian 13 support before proceeding." ;;
    esac
}

validate_commands() {
    PHASE="dependency validation"
    local cmd
    for cmd in apt-get apt-cache dpkg dpkg-query df awk sed grep cp mv mkdir date tee find readlink stat; do require_command "$cmd"; done
}

init_backup() {
    PHASE="backup initialization"
    local stamp
    stamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="${BACKUP_ROOT%/}/$stamp"
    LOG_FILE="$BACKUP_DIR/upgrade.log"
    if ((DRY_RUN)); then log_info "Would create backup directory: $BACKUP_DIR"; return 0; fi
    mkdir -p "$BACKUP_DIR"
    chmod 0700 "$BACKUP_DIR"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

check_dpkg_health() {
    PHASE="package database health"
    dpkg --audit || die "dpkg reports an inconsistent package database. Repair it before upgrading."
    if [[ -e /var/lib/dpkg/updates/0000 ]] || find /var/lib/dpkg/updates -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
        die "Pending dpkg update fragments detected. Run 'dpkg --configure -a' before upgrading."
    fi
    apt-get check >/dev/null || die "APT dependency check failed. Repair package state before upgrading."
}

check_filesystems() {
    PHASE="filesystem checks"
    touch /var/lib/apt/.trixie-upgrade-write-test
    rm -f /var/lib/apt/.trixie-upgrade-write-test
    local root_kb var_kb boot_kb
    root_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    var_kb=$(df -Pk /var | awk 'NR==2 {print $4}')
    [[ -d /boot ]] && boot_kb=$(df -Pk /boot | awk 'NR==2 {print $4}') || boot_kb=$root_kb
    ((root_kb >= 3145728)) || die "Less than 3 GiB free on /. Free space before upgrading."
    ((var_kb >= 3145728)) || die "Less than 3 GiB free on /var. Free space before upgrading."
    ((boot_kb >= 262144)) || die "Less than 256 MiB free on /boot. Remove obsolete kernels manually before upgrading."
}

check_network() {
    PHASE="network validation"
    apt-get update -o Acquire::Retries=2 -o APT::Get::List-Cleanup=0 >/dev/null || die "APT cannot refresh package metadata. Fix repository/network errors before upgrading."
}

backup_system_state() {
    PHASE="system backup"
    ((DRY_RUN)) && { log_info "Would back up APT sources and system/package state."; return 0; }
    mkdir -p "$BACKUP_DIR/etc-apt"
    cp -a /etc/apt/sources.list "$BACKUP_DIR/etc-apt/" 2>/dev/null || true
    cp -a /etc/apt/sources.list.d "$BACKUP_DIR/etc-apt/" 2>/dev/null || true
    cp -a /etc/apt/preferences "$BACKUP_DIR/etc-apt/" 2>/dev/null || true
    cp -a /etc/apt/preferences.d "$BACKUP_DIR/etc-apt/" 2>/dev/null || true
    cp -a /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
    dpkg --get-selections > "$BACKUP_DIR/package-selections.txt"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP_DIR/installed-packages.tsv"
    apt-mark showhold > "$BACKUP_DIR/held-packages.txt"
    apt-mark showmanual > "$BACKUP_DIR/manual-packages.txt"
    cp /etc/os-release "$BACKUP_DIR/os-release.before"
    uname -a > "$BACKUP_DIR/uname.before.txt"
    df -hT > "$BACKUP_DIR/filesystems.before.txt"
}

list_source_files() {
    local files=()
    [[ -f /etc/apt/sources.list ]] && files+=(/etc/apt/sources.list)
    while IFS= read -r -d '' file; do files+=("$file"); done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null | sort -z)
    printf '%s\n' "${files[@]}"
}

is_debian_source_file() {
    grep -Eqi '(^|[[:space:]/])(deb\.debian\.org|security\.debian\.org|ftp\.[^[:space:]]*\.debian\.org)([/:[:space:]]|$)' "$1"
}

source_has_third_party() {
    grep -E '^[[:space:]]*(deb|deb-src)[[:space:]]+' "$1" 2>/dev/null | grep -Ev '(deb\.debian\.org|security\.debian\.org|\.debian\.org)' >/dev/null 2>&1
}

inventory_sources() {
    PHASE="APT source inventory"
    mapfile -t SOURCE_FILES < <(list_source_files)
    ((${#SOURCE_FILES[@]} > 0)) || die "No APT source files found."
    local file
    THIRD_PARTY_FILES=(); DEBIAN_FILES=()
    for file in "${SOURCE_FILES[@]}"; do
        is_debian_source_file "$file" && DEBIAN_FILES+=("$file")
        if source_has_third_party "$file" || { [[ $file == *.sources ]] && ! is_debian_source_file "$file"; }; then THIRD_PARTY_FILES+=("$file"); fi
    done
    ((${#DEBIAN_FILES[@]} > 0)) || die "No official Debian repository source was detected."
    if ((${#THIRD_PARTY_FILES[@]})); then
        log_warning "Third-party APT source files detected:"
        printf '  %s\n' "${THIRD_PARTY_FILES[@]}"
        ((ALLOW_THIRD_PARTY)) || log_warning "They will be disabled during the distribution transition and preserved in the backup."
    fi
}

rewrite_list_file() {
    awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    $1 == "deb" || $1 == "deb-src" {
        if ($0 ~ /(deb\.debian\.org|security\.debian\.org|\.debian\.org)/) {
            gsub(/bookworm-backports/, "trixie-backports"); gsub(/bookworm-security/, "trixie-security");
            gsub(/bookworm-updates/, "trixie-updates"); gsub(/bookworm-proposed-updates/, "trixie-proposed-updates"); gsub(/bookworm/, "trixie")
        }
    }
    { print }
    ' "$1" > "$2"
}

rewrite_sources_file() {
    awk '
    BEGIN { debian=0 }
    /^URIs:/ { debian = ($0 ~ /(deb\.debian\.org|security\.debian\.org|\.debian\.org)/); print; next }
    debian && /^Suites:/ {
        gsub(/bookworm-backports/, "trixie-backports"); gsub(/bookworm-security/, "trixie-security");
        gsub(/bookworm-updates/, "trixie-updates"); gsub(/bookworm-proposed-updates/, "trixie-proposed-updates"); gsub(/bookworm/, "trixie"); print; next
    }
    /^$/ { debian=0 }
    { print }
    ' "$1" > "$2"
}

disable_third_party_sources() {
    ((ALLOW_THIRD_PARTY)) && return 0
    local file
    for file in "${THIRD_PARTY_FILES[@]}"; do
        if ((DRY_RUN)); then log_info "Would disable third-party source file: $file"; else
            [[ -e "$file.disabled-by-trixie-upgrade" ]] && die "Refusing to overwrite existing $file.disabled-by-trixie-upgrade"
            mv "$file" "$file.disabled-by-trixie-upgrade"
        fi
    done
}

rewrite_debian_sources() {
    PHASE="APT source migration"
    local file tmp
    for file in "${DEBIAN_FILES[@]}"; do
        [[ -f "$file" ]] || continue
        tmp=$(mktemp)
        [[ $file == *.sources ]] && rewrite_sources_file "$file" "$tmp" || rewrite_list_file "$file" "$tmp"
        grep -q "$TARGET_CODENAME" "$tmp" || { rm -f "$tmp"; die "Migration produced no $TARGET_CODENAME suite in $file"; }
        if ((DRY_RUN)); then log_info "Would migrate official Debian suites in $file"; rm -f "$tmp"; else
            cp -a "$file" "$file.bookworm-backup"; cat "$tmp" > "$file"; rm -f "$tmp"
        fi
    done
    disable_third_party_sources
}

restore_sources() {
    ((DRY_RUN)) && return 0
    [[ -d "$BACKUP_DIR/etc-apt" ]] || return 0
    log_warning "Restoring APT source configuration from backup after validation failure."
    rm -f /etc/apt/sources.list; rm -rf /etc/apt/sources.list.d
    [[ -f "$BACKUP_DIR/etc-apt/sources.list" ]] && cp -a "$BACKUP_DIR/etc-apt/sources.list" /etc/apt/sources.list
    [[ -d "$BACKUP_DIR/etc-apt/sources.list.d" ]] && cp -a "$BACKUP_DIR/etc-apt/sources.list.d" /etc/apt/sources.list.d
}

validate_migrated_sources() {
    PHASE="APT source validation"
    ((DRY_RUN)) && { log_info "Would run apt-get update against migrated sources."; return 0; }
    if ! apt-get update -o Acquire::Retries=2; then restore_sources; apt-get update -o Acquire::Retries=2 || true; die "Trixie APT source validation failed; original source configuration was restored."; fi
    if grep -RhsE '^[[:space:]]*(deb|deb-src).*bookworm([[:space:]-]|$)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -v 'disabled-by-trixie-upgrade' >/dev/null; then restore_sources; die "Active Bookworm entries remain after migration; sources were restored."; fi
}

calculate_upgrade() {
    PHASE="upgrade simulation"
    local sim="$BACKUP_DIR/full-upgrade.simulation.txt" removals
    ((DRY_RUN)) && { log_info "Would simulate apt-get full-upgrade."; return 0; }
    apt-get -s full-upgrade | tee "$sim"
    removals=$(grep -E '^Remv ' "$sim" | wc -l | tr -d ' ')
    log_info "Upgrade simulation reports $removals package removals."
}

update_bookworm() {
    PHASE="Bookworm refresh"
    run apt-get update -o Acquire::Retries=2
    run apt-get upgrade -y
    run apt-get full-upgrade -y
}

perform_upgrade() {
    PHASE="Trixie upgrade"
    local apt_args=(-y)
    if ((NON_INTERACTIVE)); then export DEBIAN_FRONTEND=noninteractive; apt_args+=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold); fi
    run apt-get upgrade "${apt_args[@]}" --without-new-pkgs
    run apt-get full-upgrade "${apt_args[@]}"
}

verify_upgrade() {
    PHASE="post-upgrade verification"
    ((DRY_RUN)) && { log_success "Dry run completed; no system changes were made."; return 0; }
    load_os_release
    [[ ${ID:-} == debian ]] || die "Post-upgrade OS identity is not Debian."
    [[ ${VERSION_ID:-} == "$TARGET_VERSION_ID" ]] || die "Upgrade incomplete: expected VERSION_ID=$TARGET_VERSION_ID, got ${VERSION_ID:-unknown}."
    [[ ${VERSION_CODENAME:-} == "$TARGET_CODENAME" ]] || die "Upgrade incomplete: expected codename $TARGET_CODENAME, got ${VERSION_CODENAME:-unknown}."
    dpkg --audit; apt-get check
    apt list --upgradable 2>/dev/null | sed 1d | grep -q . && log_warning "Some packages remain upgradable. Review them before considering the machine fully settled." || true
    systemctl --failed --no-legend 2>/dev/null | tee "$BACKUP_DIR/failed-services.after.txt" || true
    cp /etc/os-release "$BACKUP_DIR/os-release.after"
    dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP_DIR/installed-packages.after.tsv"
    log_success "Verified Debian $TARGET_VERSION_ID ($TARGET_CODENAME) and consistent package state."
}

maybe_reboot() {
    ((DRY_RUN || NO_REBOOT)) && return 0
    log_warning "A reboot is recommended to activate the new kernel and services."
    confirm "Reboot now?" && reboot || true
}

main() {
    parse_args "$@"
    printf 'Debian Bookworm → Trixie Upgrade Safety Tool v%s\n' "$SCRIPT_VERSION"
    validate_commands; validate_platform; init_backup; check_dpkg_health; check_filesystems; inventory_sources; check_network; backup_system_state
    ((!DRY_RUN)) && { confirm "Proceed with the Bookworm refresh and Trixie migration?" || die "Upgrade cancelled."; }
    update_bookworm; rewrite_debian_sources; validate_migrated_sources; calculate_upgrade
    if ((!DRY_RUN && !NON_INTERACTIVE && !ASSUME_YES)); then confirm "Proceed with the simulated Trixie package changes shown above?" || { restore_sources; die "Upgrade cancelled; APT sources restored."; }; fi
    perform_upgrade; verify_upgrade; maybe_reboot
    log_success "Upgrade workflow complete. Backup: ${BACKUP_DIR:-not-created}"
}

main "$@"
