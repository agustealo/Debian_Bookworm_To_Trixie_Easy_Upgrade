#!/bin/bash

# Script to upgrade Debian from Bookworm to Trixie
# Run this script with sudo privileges

echo "=== Debian Bookworm to Trixie Upgrade Script ==="
echo "This script will upgrade your system to Debian Trixie (testing)"
echo "Make sure you have backed up important data before proceeding"
echo ""

# Step 1: Create backup directory
echo "Step 1: Creating backup directory..."
BACKUP_DIR="/home/zeus/Documents/system_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "Backup directory created: $BACKUP_DIR"
echo ""

# Step 2: Backup current system configuration
echo "Step 2: Backing up system configuration..."
cp /etc/apt/sources.list "$BACKUP_DIR/"
cp -r /etc/apt/sources.list.d "$BACKUP_DIR/"
cp /etc/fstab "$BACKUP_DIR/"
cp -r /etc/network/ "$BACKUP_DIR/"
cp -r /etc/default/ "$BACKUP_DIR/" 2>/dev/null || true
echo "System configuration backed up"
echo ""

# Step 3: Update current system to latest Bookworm packages
echo "Step 3: Updating current Bookworm system..."
apt update
apt upgrade -y
apt dist-upgrade -y
echo "Current system updated"
echo ""

# Step 4: Modify sources.list to point to Trixie
echo "Step 4: Updating repository configuration..."
cp /etc/apt/sources.list /etc/apt/sources.list.bookworm_backup

# Replace bookworm with trixie in sources.list
sed -i 's/bookworm/trixie/g' /etc/apt/sources.list

# Update sources.list.d files
for file in /etc/apt/sources.list.d/*.list; do
    if [ -f "$file" ]; then
        sed -i 's/bookworm/trixie/g' "$file"
    fi
done

# Handle .sources files (like vscode.sources)
for file in /etc/apt/sources.list.d/*.sources; do
    if [ -f "$file" ]; then
        # For .sources files, we need to be more careful
        # Only change Debian-specific repositories, not third-party ones
        sed -i 's/Suites: bookworm/Suites: trixie/g' "$file"
    fi
done

echo "Repository configuration updated to Trixie"
echo ""

# Step 5: Update package lists
echo "Step 5: Updating package lists for Trixie..."
apt update
echo ""

# Step 6: Perform system upgrade to Trixie
echo "Step 6: Starting system upgrade to Trixie..."
echo "This may take a while and may require interaction for configuration files"
echo ""

# Perform the upgrade
apt full-upgrade -y

echo ""
echo "=== Upgrade completed ==="
echo "Please check if everything is working correctly"
echo "You may need to reboot your system"
echo ""

# Step 7: Clean up
echo "Step 7: Cleaning up..."
apt autoremove -y
apt autoclean
echo "Cleanup completed"
echo ""

echo "=== Upgrade process finished ==="
echo "Your system should now be running Debian Trixie"
echo "If you encounter any issues, check the backup at: $BACKUP_DIR"
