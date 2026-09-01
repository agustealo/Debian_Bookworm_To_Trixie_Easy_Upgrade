#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
SOURCE_CODENAME="bookworm"
TARGET_CODENAME="trixie"
TARGET_VERSION_ID="13"
APT_ROOT="${APT_ROOT:-/etc/apt}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/debian-bookworm-to-trixie}"
BACKUP_DIR="" LOG_FILE="" PHASE="startup"
DRY_RUN=0 NON_INTERACTIVE=0 ASSUME_YES=0 NO_REBOOT=0 ALLOW_THIRD_PARTY=0
SOURCE_FILES=() DEBIAN_FILES=() THIRD_PARTY_FILES=()
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log_info(){ printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*"; }
log_success(){ printf '%b[SUCCESS]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warning(){ printf '%b[WARNING]%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error(){ printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
die(){ log_error "$*"; exit 1; }
on_error(){ local s=$?; log_error "Failure during '$PHASE' (exit $s, line ${BASH_LINENO[0]:-?}): ${BASH_COMMAND:-?}"; [[ -n "$LOG_FILE" ]] && log_error "Log: $LOG_FILE"; exit "$s"; }
trap on_error ERR

usage(){ cat <<USAGE
Usage: sudo ./debian-bookworm-to-trixie.sh [options]
  --dry-run             Validate and preview without changing system state
  --non-interactive     Never prompt; fail closed where confirmation is required
  --yes                 Assume yes for confirmations
  --backup-dir PATH     Backup root (default: /var/backups/debian-bookworm-to-trixie)
  --allow-third-party   Keep third-party APT sources enabled (higher risk)
  --no-reboot           Never offer to reboot
  -h, --help            Show help
USAGE
}

parse_args(){ while (($#)); do case "$1" in
  --dry-run) DRY_RUN=1;; --non-interactive) NON_INTERACTIVE=1;; --yes) ASSUME_YES=1;;
  --allow-third-party) ALLOW_THIRD_PARTY=1;; --no-reboot) NO_REBOOT=1;;
  --backup-dir) shift; (($#)) || die "--backup-dir requires a path"; BACKUP_ROOT=$1;;
  -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; shift; done; }
confirm(){ ((ASSUME_YES)) && return 0; ((NON_INTERACTIVE)) && return 1; local r; read -r -p "$1 [y/N]: " r; [[ $r =~ ^[Yy]$ ]]; }
run(){ if ((DRY_RUN)); then printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
require(){ command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }

load_os(){ [[ -r "$OS_RELEASE_FILE" ]] || die "$OS_RELEASE_FILE is missing"; unset ID VERSION_ID VERSION_CODENAME; . "$OS_RELEASE_FILE"; }
validate_platform(){
  PHASE="platform validation"; ((EUID==0)) || die "Run as root with sudo."; load_os
  [[ ${ID:-} == debian ]] || die "Debian required (ID=${ID:-unknown})."
  [[ ${VERSION_ID:-} == 12 ]] || die "Debian 12 required (VERSION_ID=${VERSION_ID:-unknown})."
  [[ ${VERSION_CODENAME:-} == "$SOURCE_CODENAME" ]] || die "Bookworm required (codename=${VERSION_CODENAME:-unknown})."
}
validate_commands(){ local c; for c in apt-get apt-mark dpkg dpkg-query df awk grep cp mv mkdir date tee find sort mktemp; do require "$c"; done; }
init_backup(){
  PHASE="backup initialization"; BACKUP_DIR="${BACKUP_ROOT%/}/$(date +%Y%m%d_%H%M%S)"; LOG_FILE="$BACKUP_DIR/upgrade.log"
  ((DRY_RUN)) && { log_info "Would create backup: $BACKUP_DIR"; return; }
  mkdir -p "$BACKUP_DIR"; chmod 0700 "$BACKUP_DIR"; exec > >(tee -a "$LOG_FILE") 2>&1
}
check_package_health(){
  PHASE="package database health"; dpkg --audit; apt-get check >/dev/null
  if find /var/lib/dpkg/updates -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then die "Pending dpkg update fragments found. Run: dpkg --configure -a"; fi
}
check_space(){
  PHASE="filesystem checks"; local r v b
  if ((!DRY_RUN)); then touch /var/lib/apt/.trixie-write-test; rm -f /var/lib/apt/.trixie-write-test; fi
  r=$(df -Pk /|awk 'NR==2{print $4}'); v=$(df -Pk /var|awk 'NR==2{print $4}'); b=$(df -Pk /boot|awk 'NR==2{print $4}')
  ((r>=3145728)) || die "Less than 3 GiB free on /."; ((v>=3145728)) || die "Less than 3 GiB free on /var."; ((b>=262144)) || die "Less than 256 MiB free on /boot."
}
check_network(){ PHASE="Bookworm repository validation"; apt-get update -o Acquire::Retries=2 -o APT::Get::List-Cleanup=0 >/dev/null || die "Current APT repositories cannot refresh."; }

list_source_files(){
  local f; [[ -f "$APT_ROOT/sources.list" ]] && printf '%s\n' "$APT_ROOT/sources.list"
  [[ -d "$APT_ROOT/sources.list.d" ]] || return 0
  while IFS= read -r -d '' f; do printf '%s\n' "$f"; done < <(find "$APT_ROOT/sources.list.d" -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -print0|sort -z)
}
is_debian_source(){ grep -Eqi '(deb\.debian\.org|security\.debian\.org|ftp\.[^[:space:]]*\.debian\.org)' "$1"; }
has_third_party_list(){ grep -E '^[[:space:]]*(deb|deb-src)[[:space:]]+' "$1" 2>/dev/null|grep -Ev '(deb\.debian\.org|security\.debian\.org|\.debian\.org)' >/dev/null 2>&1; }
inventory_sources(){
  PHASE="APT source inventory"; mapfile -t SOURCE_FILES < <(list_source_files); ((${#SOURCE_FILES[@]})) || die "No APT sources found."
  DEBIAN_FILES=(); THIRD_PARTY_FILES=(); local f d t
  for f in "${SOURCE_FILES[@]}"; do d=0; t=0; is_debian_source "$f" && d=1
    if [[ $f == *.list ]]; then has_third_party_list "$f" && t=1; elif ((!d)); then t=1; fi
    ((d&&t)) && die "Mixed official Debian and third-party entries in one file: $f. Split it before upgrading."
    ((d)) && DEBIAN_FILES+=("$f"); ((t)) && THIRD_PARTY_FILES+=("$f")
  done
  ((${#DEBIAN_FILES[@]})) || die "No official Debian source found."
  ((${#THIRD_PARTY_FILES[@]})) && { log_warning "Third-party source files detected:"; printf '  %s\n' "${THIRD_PARTY_FILES[@]}"; }
}

rewrite_list_file(){ awk '
/^[[:space:]]*#/||/^[[:space:]]*$/ {print;next}
($1=="deb"||$1=="deb-src") && $0~/(deb\.debian\.org|security\.debian\.org|\.debian\.org)/ {
 gsub(/bookworm-backports/,"trixie-backports"); gsub(/bookworm-security/,"trixie-security"); gsub(/bookworm-updates/,"trixie-updates"); gsub(/bookworm-proposed-updates/,"trixie-proposed-updates"); gsub(/bookworm/,"trixie") }
{print}' "$1" > "$2"; }
rewrite_sources_file(){ awk '
BEGIN{debian=0}
/^URIs:/ {debian=($0~/(deb\.debian\.org|security\.debian\.org|\.debian\.org)/);print;next}
debian&&/^Suites:/ {gsub(/bookworm-backports/,"trixie-backports");gsub(/bookworm-security/,"trixie-security");gsub(/bookworm-updates/,"trixie-updates");gsub(/bookworm-proposed-updates/,"trixie-proposed-updates");gsub(/bookworm/,"trixie");print;next}
/^$/{debian=0}{print}' "$1" > "$2"; }

backup_state(){
  PHASE="system backup"; ((DRY_RUN)) && { log_info "Would back up APT and package state."; return; }
  mkdir -p "$BACKUP_DIR/apt"; cp -a "$APT_ROOT/sources.list" "$BACKUP_DIR/apt/" 2>/dev/null||true; cp -a "$APT_ROOT/sources.list.d" "$BACKUP_DIR/apt/" 2>/dev/null||true
  cp -a "$APT_ROOT/preferences" "$BACKUP_DIR/apt/" 2>/dev/null||true; cp -a "$APT_ROOT/preferences.d" "$BACKUP_DIR/apt/" 2>/dev/null||true
  cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null||true; dpkg --get-selections > "$BACKUP_DIR/package-selections.txt"; apt-mark showhold > "$BACKUP_DIR/held-packages.txt"
  dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP_DIR/installed-packages.before.tsv"; cp "$OS_RELEASE_FILE" "$BACKUP_DIR/os-release.before"
}
disable_third_party(){ ((ALLOW_THIRD_PARTY)) && return; local f; for f in "${THIRD_PARTY_FILES[@]}"; do
  ((DRY_RUN)) && { log_info "Would disable $f"; continue; }; [[ ! -e "$f.disabled-by-trixie-upgrade" ]] || die "Disable target exists: $f.disabled-by-trixie-upgrade"; mv "$f" "$f.disabled-by-trixie-upgrade"; done; }
migrate_sources(){
  PHASE="APT source migration"; local f tmp
  for f in "${DEBIAN_FILES[@]}"; do tmp=$(mktemp); [[ $f == *.sources ]] && rewrite_sources_file "$f" "$tmp" || rewrite_list_file "$f" "$tmp"
    grep -q "$TARGET_CODENAME" "$tmp" || { rm -f "$tmp"; die "No Trixie suite produced for $f"; }
    if ((DRY_RUN)); then log_info "Would migrate $f"; rm -f "$tmp"; else cp -a "$f" "$f.bookworm-backup"; cat "$tmp" > "$f"; rm -f "$tmp"; fi
  done; disable_third_party
}
restore_sources(){
  ((DRY_RUN)) && return; [[ -d "$BACKUP_DIR/apt" ]] || return; log_warning "Restoring original APT sources."
  rm -f "$APT_ROOT/sources.list"; rm -rf "$APT_ROOT/sources.list.d"; [[ -f "$BACKUP_DIR/apt/sources.list" ]] && cp -a "$BACKUP_DIR/apt/sources.list" "$APT_ROOT/sources.list"
  [[ -d "$BACKUP_DIR/apt/sources.list.d" ]] && cp -a "$BACKUP_DIR/apt/sources.list.d" "$APT_ROOT/sources.list.d"
}
validate_migrated_sources(){
  PHASE="Trixie repository validation"; ((DRY_RUN)) && { log_info "Would validate migrated repositories with apt-get update."; return; }
  if ! apt-get update -o Acquire::Retries=2; then restore_sources; apt-get update -o Acquire::Retries=2||true; die "Trixie repository validation failed; sources restored."; fi
  if grep -RhsE '^[[:space:]]*(deb|deb-src).*bookworm([[:space:]-]|$)' "$APT_ROOT/sources.list" "$APT_ROOT/sources.list.d" 2>/dev/null|grep -v disabled-by-trixie-upgrade >/dev/null; then restore_sources; die "Active Bookworm entries remain; sources restored."; fi
}

refresh_bookworm(){ PHASE="Bookworm refresh"; run apt-get update -o Acquire::Retries=2; run apt-get upgrade -y; run apt-get full-upgrade -y; }
simulate_upgrade(){ PHASE="upgrade simulation"; ((DRY_RUN)) && { log_info "Would simulate full-upgrade."; return; }; apt-get -s full-upgrade|tee "$BACKUP_DIR/full-upgrade.simulation.txt"; }
upgrade_trixie(){
  PHASE="Trixie package upgrade"; local a=(-y); if ((NON_INTERACTIVE)); then export DEBIAN_FRONTEND=noninteractive; a+=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold); fi
  run apt-get upgrade "${a[@]}" --without-new-pkgs; run apt-get full-upgrade "${a[@]}"
}
verify_upgrade(){
  PHASE="post-upgrade verification"; ((DRY_RUN)) && { log_success "Dry run complete; no system changes made."; return; }; load_os
  [[ ${ID:-} == debian && ${VERSION_ID:-} == "$TARGET_VERSION_ID" && ${VERSION_CODENAME:-} == "$TARGET_CODENAME" ]] || die "Upgrade is not verified as Debian 13 Trixie."
  dpkg --audit; apt-get check; dpkg-query -W -f='${binary:Package}\t${Version}\n' > "$BACKUP_DIR/installed-packages.after.tsv"
  systemctl --failed --no-legend 2>/dev/null|tee "$BACKUP_DIR/failed-services.after.txt"||true; log_success "Verified Debian 13 (Trixie) and consistent package state."
}
maybe_reboot(){ ((DRY_RUN||NO_REBOOT)) && return; log_warning "Reboot recommended."; confirm "Reboot now?" && reboot || true; }

main(){
  parse_args "$@"; printf 'Debian Bookworm → Trixie Safety Tool v%s\n' "$VERSION"
  validate_commands; validate_platform; init_backup; check_package_health; check_space; inventory_sources; check_network; backup_state
  ((!DRY_RUN)) && { confirm "Proceed with Bookworm refresh and Trixie source migration?" || die "Cancelled."; }
  refresh_bookworm; migrate_sources; validate_migrated_sources; simulate_upgrade
  if ((!DRY_RUN&&!NON_INTERACTIVE&&!ASSUME_YES)); then confirm "Proceed with Trixie package upgrade?" || { restore_sources; die "Cancelled; sources restored."; }; fi
  upgrade_trixie; verify_upgrade; maybe_reboot; log_success "Workflow complete. Backup: ${BACKUP_DIR:-not-created}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
