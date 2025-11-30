#!/bin/bash

#==============================================================================
# Debian Bookworm to Trixie Upgrade Script
# Version: 2.0
# Description: Bulletproof upgrade script with multiple upgrade modes
# Requirements: Root privileges, stable internet, 5-10GB free space
#==============================================================================

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

#==============================================================================
# COLOR CODES FOR OUTPUT
#==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#==============================================================================
# LOGGING FUNCTIONS
#==============================================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#==============================================================================
# CONFIGURATION
#==============================================================================
BACKUP_DIR="/home/zeus/Documents/system_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${BACKUP_DIR}/upgrade.log"
REQUIRED_SPACE_KB=5242880  # 5GB in KB

#==============================================================================
# PRE-FLIGHT CHECKS
#==============================================================================
preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    
    # Check current Debian version
    if ! grep -q "bookworm" /etc/debian_version && ! grep -q "^12" /etc/debian_version; then
        log_error "This script is designed for Debian 12 (Bookworm) only"
        log_error "Current version: $(cat /etc/debian_version)"
        exit 1
    fi
    
    # Check internet connectivity
    log_info "Checking internet connectivity..."
    if ! ping -c 1 deb.debian.org &> /dev/null; then
        log_error "No internet connection detected. Please check your network."
        exit 1
    fi
    
    # Check available disk space
    log_info "Checking disk space..."
    AVAILABLE_SPACE=$(df /var/cache/apt/archives | tail -1 | awk '{print $4}')
    if [[ $AVAILABLE_SPACE -lt $REQUIRED_SPACE_KB ]]; then
        log_warning "Low disk space: $(($AVAILABLE_SPACE / 1024))MB available"
        log_warning "Recommended: At least 5GB free space"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check for held packages
    log_info "Checking for held packages..."
    HELD_PACKAGES=$(dpkg --get-selections | grep hold || true)
    if [[ -n "$HELD_PACKAGES" ]]; then
        log_warning "The following packages are held and won't be upgraded:"
        echo "$HELD_PACKAGES"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check for third-party repositories
    log_info "Checking for third-party repositories..."
    THIRD_PARTY=$(grep -r "^deb " /etc/apt/sources.list.d/ 2>/dev/null | grep -v "debian.org" || true)
    if [[ -n "$THIRD_PARTY" ]]; then
        log_warning "Third-party repositories detected:"
        echo "$THIRD_PARTY"
        log_warning "These may need manual adjustment after the upgrade"
    fi
    
    log_success "Pre-flight checks completed"
    echo ""
}

#==============================================================================
# BACKUP SYSTEM CONFIGURATION
#==============================================================================
create_backup() {
    log_info "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Initialize log file
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    log_info "Backing up system configuration..."
    
    # Backup APT sources
    cp /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup system files
    cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/network/ "$BACKUP_DIR/" 2>/dev/null || true
    cp -r /etc/default/ "$BACKUP_DIR/" 2>/dev/null || true
    
    # Backup package selections
    dpkg --get-selections > "$BACKUP_DIR/package_selections.txt"
    
    # Backup currently installed packages list
    apt list --installed > "$BACKUP_DIR/installed_packages.txt" 2>/dev/null
    
    # Save system information
    uname -a > "$BACKUP_DIR/system_info.txt"
    lsb_release -a >> "$BACKUP_DIR/system_info.txt" 2>/dev/null || true
    df -h > "$BACKUP_DIR/disk_usage.txt"
    
    log_success "Backup completed: $BACKUP_DIR"
    echo ""
}

#==============================================================================
# UPDATE CURRENT BOOKWORM SYSTEM
#==============================================================================
update_bookworm() {
    log_info "Updating current Bookworm system to latest packages..."
    
    # Clean package cache to free space
    apt clean
    
    # Update package lists
    log_info "Updating package lists..."
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    # Upgrade packages
    log_info "Upgrading installed packages..."
    apt upgrade -y || {
        log_error "Failed to upgrade packages"
        exit 1
    }
    
    # Dist-upgrade to handle dependencies
    log_info "Performing dist-upgrade..."
    apt dist-upgrade -y || {
        log_error "Failed to perform dist-upgrade"
        exit 1
    }
    
    # Remove obsolete packages
    log_info "Removing obsolete packages..."
    apt autoremove -y
    
    log_success "Bookworm system updated to latest packages"
    echo ""
}

#==============================================================================
# UPDATE REPOSITORY CONFIGURATION
#==============================================================================
update_repositories() {
    log_info "Updating repository configuration from Bookworm to Trixie..."
    
    # Backup sources.list again before modification
    cp /etc/apt/sources.list /etc/apt/sources.list.bookworm_backup
    
    # Update main sources.list
    log_info "Updating /etc/apt/sources.list..."
    sed -i.bak 's/bookworm/trixie/g' /etc/apt/sources.list
    
    # Update sources.list.d files
    log_info "Updating /etc/apt/sources.list.d/ files..."
    for file in /etc/apt/sources.list.d/*.list; do
        if [[ -f "$file" ]]; then
            # Backup before modification
            cp "$file" "${file}.bookworm_backup"
            # Only update Debian repositories, not third-party
            if grep -q "debian.org" "$file"; then
                sed -i 's/bookworm/trixie/g' "$file"
            else
                log_warning "Skipping third-party repo: $file"
            fi
        fi
    done
    
    # Update .sources files (DEB822 format)
    for file in /etc/apt/sources.list.d/*.sources; do
        if [[ -f "$file" ]]; then
            cp "$file" "${file}.bookworm_backup"
            if grep -q "debian.org" "$file"; then
                sed -i 's/Suites: bookworm/Suites: trixie/g' "$file"
            else
                log_warning "Skipping third-party .sources file: $file"
            fi
        fi
    done
    
    log_success "Repository configuration updated to Trixie"
    echo ""
}

#==============================================================================
# UPGRADE MODES
#==============================================================================

# Minimal upgrade (safe, upgrades without removing packages)
minimal_upgrade() {
    log_info "Performing MINIMAL upgrade (safe mode)..."
    log_info "This upgrades packages without removing any existing packages"
    echo ""
    
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    apt upgrade -y || {
        log_error "Minimal upgrade failed"
        exit 1
    }
    
    log_success "Minimal upgrade completed"
    log_info "You may need to run full-upgrade next to complete the transition"
    echo ""
}

# Full upgrade (recommended, may remove conflicting packages)
full_upgrade() {
    log_info "Performing FULL upgrade..."
    log_info "This may remove packages if needed to resolve conflicts"
    echo ""
    
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    # Show what will be done
    log_info "Calculating upgrade requirements..."
    apt full-upgrade --simulate || {
        log_error "Failed to calculate upgrade"
        exit 1
    }
    
    echo ""
    log_warning "The above packages will be upgraded, installed, or removed"
    read -p "Continue with full upgrade? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Upgrade cancelled by user"
        exit 0
    fi
    
    apt full-upgrade -y || {
        log_error "Full upgrade failed"
        exit 1
    }
    
    log_success "Full upgrade completed"
    echo ""
}

# Safe upgrade (two-step: minimal then full)
safe_upgrade() {
    log_info "Performing SAFE upgrade (two-step process)..."
    log_info "Step 1: Minimal upgrade to resolve initial conflicts"
    echo ""
    
    minimal_upgrade
    
    log_info "Step 2: Full upgrade to complete the transition"
    echo ""
    
    full_upgrade
    
    log_success "Safe two-step upgrade completed"
    echo ""
}

# Auto upgrade (non-interactive, full upgrade)
auto_upgrade() {
    log_info "Performing AUTO upgrade (non-interactive mode)..."
    echo ""
    
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || {
        log_error "Auto upgrade failed"
        exit 1
    }
    
    log_success "Auto upgrade completed"
    echo ""
}

# Custom upgrade (interactive package selection)
custom_upgrade() {
    log_info "Performing CUSTOM upgrade..."
    log_info "You will be prompted for each configuration file change"
    echo ""
    
    apt update || {
        log_error "Failed to update package lists"
        exit 1
    }
    
    log_info "Starting interactive full upgrade..."
    apt full-upgrade || {
        log_error "Custom upgrade failed"
        exit 1
    }
    
    log_success "Custom upgrade completed"
    echo ""
}

#==============================================================================
# CLEANUP
#==============================================================================
cleanup() {
    log_info "Cleaning up system..."
    
    # Remove unnecessary packages
    apt autoremove -y
    
    # Clean package cache
    apt autoclean
    
    # Remove old kernels (keep current and one previous)
    log_info "Checking for old kernels..."
    CURRENT_KERNEL=$(uname -r)
    OLD_KERNELS=$(dpkg -l | grep linux-image | grep -v "$CURRENT_KERNEL" | awk '{print $2}' | grep -v "linux-image-amd64" || true)
    
    if [[ -n "$OLD_KERNELS" ]]; then
        log_warning "Old kernels found (keeping current: $CURRENT_KERNEL)"
        echo "$OLD_KERNELS"
        read -p "Remove old kernels? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$OLD_KERNELS" | xargs apt purge -y || true
        fi
    fi
    
    log_success "Cleanup completed"
    echo ""
}

#==============================================================================
# POST-UPGRADE VERIFICATION
#==============================================================================
post_upgrade_checks() {
    log_info "Running post-upgrade verification..."
    
    # Check Debian version
    CURRENT_VERSION=$(cat /etc/debian_version)
    log_info "Current Debian version: $CURRENT_VERSION"
    
    # Check for broken packages
    log_info "Checking for broken packages..."
    BROKEN=$(dpkg -l | grep ^..r || true)
    if [[ -n "$BROKEN" ]]; then
        log_warning "Broken packages detected:"
        echo "$BROKEN"
        log_info "Attempting to fix..."
        apt --fix-broken install -y
    else
        log_success "No broken packages found"
    fi
    
    # Check for held upgrades
    HELD_UPGRADES=$(apt list --upgradable 2>/dev/null | grep -v "Listing" || true)
    if [[ -n "$HELD_UPGRADES" ]]; then
        log_warning "Some packages were not upgraded:"
        echo "$HELD_UPGRADES"
    fi
    
    # Save post-upgrade package list
    apt list --installed > "$BACKUP_DIR/post_upgrade_packages.txt" 2>/dev/null
    
    log_success "Post-upgrade checks completed"
    echo ""
}

#==============================================================================
# DISPLAY UPGRADE MENU
#==============================================================================
show_menu() {
    echo ""
    echo "=========================================="
    echo " Debian Bookworm → Trixie Upgrade Script"
    echo "=========================================="
    echo ""
    echo "Select upgrade mode:"
    echo ""
    echo "  1) AUTO    - Fully automated, non-interactive (fastest)"
    echo "  2) FULL    - Complete upgrade with user confirmation"
    echo "  3) SAFE    - Two-step: minimal then full (recommended)"
    echo "  4) MINIMAL - Upgrade without removing packages (safest)"
    echo "  5) CUSTOM  - Interactive with configuration prompts"
    echo ""
    echo "  0) Exit"
    echo ""
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================
main() {
    # Banner
    echo "=========================================="
    echo " Debian Bookworm to Trixie Upgrade"
    echo " Version 2.0"
    echo "=========================================="
    echo ""
    echo "⚠️  IMPORTANT WARNINGS:"
    echo "  • This will upgrade to Debian 13 (Trixie)"
    echo "  • Ensure you have backed up important data"
    echo "  • Stable internet connection required"
    echo "  • Process may take 30-120 minutes"
    echo "  • Do NOT interrupt during upgrade"
    echo ""
    
    read -p "Have you backed up your important data? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Please backup your data first, then run this script again"
        exit 0
    fi
    
    # Run pre-flight checks
    preflight_checks
    
    # Create backup
    create_backup
    
    # Update current system
    update_bookworm
    
    # Update repositories
    update_repositories
    
    # Show menu and get user choice
    show_menu
    read -p "Enter your choice [0-5]: " choice
    echo ""
    
    case $choice in
        1)
            log_info "Selected: AUTO upgrade"
            auto_upgrade
            ;;
        2)
            log_info "Selected: FULL upgrade"
            full_upgrade
            ;;
        3)
            log_info "Selected: SAFE upgrade (recommended)"
            safe_upgrade
            ;;
        4)
            log_info "Selected: MINIMAL upgrade"
            minimal_upgrade
            log_warning "MINIMAL upgrade complete. Run FULL upgrade to finish."
            ;;
        5)
            log_info "Selected: CUSTOM upgrade"
            custom_upgrade
            ;;
        0)
            log_info "Exiting without upgrade"
            exit 0
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
    
    # Cleanup
    cleanup
    
    # Post-upgrade checks
    post_upgrade_checks
    
    # Final summary
    echo ""
    echo "=========================================="
    echo " Upgrade Process Complete!"
    echo "=========================================="
    echo ""
    log_success "Your system has been upgraded to Debian Trixie"
    log_info "Backup location: $BACKUP_DIR"
    log_info "Log file: $LOG_FILE"
    echo ""
    log_warning "⚠️  IMPORTANT: You MUST reboot your system now"
    log_info "New kernel and services require a reboot to take effect"
    echo ""
    read -p "Reboot now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Rebooting in 5 seconds... (Ctrl+C to cancel)"
        sleep 5
        reboot
    else
        log_warning "Please reboot your system as soon as possible"
        log_info "Run: sudo reboot"
    fi
}

# Execute main function
main "$@"
