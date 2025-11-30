# Debian Bookworm to Trixie Upgrade Script

A bulletproof, production-ready script for upgrading Debian 12 (Bookworm) to Debian 13 (Trixie) with multiple upgrade modes and comprehensive safety features.

## ✨ Features

### 🛡️ Safety Features
- **Pre-flight checks** - Validates system requirements before starting
- **Automatic backups** - Creates timestamped backups of critical system files
- **Internet connectivity check** - Ensures stable connection before upgrade
- **Disk space validation** - Warns if insufficient space available
- **Held package detection** - Identifies packages that won't upgrade
- **Third-party repo detection** - Warns about non-Debian repositories
- **Error handling** - Exits safely on errors with detailed logging

### 📊 Comprehensive Logging
- Color-coded console output (Info, Success, Warning, Error)
- Complete upgrade log saved to backup directory
- Pre and post-upgrade package lists for comparison
- System information snapshot

### 🎯 Multiple Upgrade Modes

1. **AUTO** - Fully automated, non-interactive (fastest)
   - Best for: Experienced users, scripted deployments
   - Uses default answers for all prompts
   - Keeps existing configuration files

2. **FULL** - Complete upgrade with user confirmation
   - Best for: Most users
   - Shows preview of changes before proceeding
   - Allows reviewing what will be upgraded/removed

3. **SAFE** - Two-step process: minimal then full (recommended)
   - Best for: Maximum safety, critical systems
   - Follows Debian's official recommendation
   - Minimizes risk of conflicts

4. **MINIMAL** - Upgrades without removing packages (safest)
   - Best for: Testing, cautious users
   - Only installs safe upgrades
   - Requires full upgrade as second step

5. **CUSTOM** - Interactive with configuration prompts
   - Best for: Advanced users who want control
   - Prompts for each configuration file conflict
   - Allows manual decision-making

## 📋 Requirements

- Debian 12 (Bookworm) installed
- Root/sudo privileges
- Stable internet connection
- **Minimum 5-10 GB free disk space**
- Backed up important data

## 🚀 Usage

### Basic Usage

1. Download the script:
```bash
wget https://your-server.com/debian_upgrade_bookworm_to_trixie.sh
# or
curl -O https://your-server.com/debian_upgrade_bookworm_to_trixie.sh
```

2. Make it executable:
```bash
chmod +x debian_upgrade_bookworm_to_trixie.sh
```

3. Run with sudo:
```bash
sudo ./debian_upgrade_bookworm_to_trixie.sh
```

4. Follow the on-screen prompts and select your preferred upgrade mode

### Recommended Workflow

```bash
# 1. Update your current system first
sudo apt update && sudo apt upgrade -y

# 2. Backup important data manually
# Backup your /home directory and any custom configurations

# 3. Run the upgrade script
sudo ./debian_upgrade_bookworm_to_trixie.sh

# 4. Select SAFE mode (option 3) for maximum reliability

# 5. Reboot when prompted
sudo reboot
```

## 📖 What the Script Does

### Step 1: Pre-flight Checks
- ✅ Verifies root privileges
- ✅ Confirms Debian 12 (Bookworm) is running
- ✅ Tests internet connectivity
- ✅ Checks available disk space
- ✅ Identifies held packages
- ✅ Detects third-party repositories

### Step 2: Backup Creation
Creates timestamped backup directory containing:
- `/etc/apt/sources.list` - APT repository configuration
- `/etc/apt/sources.list.d/` - Additional repository configurations
- `/etc/fstab` - Filesystem mount configuration
- `/etc/network/` - Network configuration
- `/etc/default/` - System defaults
- `package_selections.txt` - Current package selections
- `installed_packages.txt` - List of all installed packages
- `system_info.txt` - System information snapshot
- `disk_usage.txt` - Current disk usage
- `upgrade.log` - Complete upgrade log (created during upgrade)

### Step 3: Update Bookworm System
- Updates package lists
- Upgrades all packages to latest Bookworm versions
- Performs dist-upgrade to handle dependencies
- Removes obsolete packages

### Step 4: Update Repository Configuration
- Backs up sources.list
- Changes all "bookworm" references to "trixie"
- Updates `.list` files in sources.list.d
- Updates `.sources` files (DEB822 format)
- **Preserves third-party repositories** (with warnings)

### Step 5: Perform Upgrade
Executes selected upgrade mode (AUTO/FULL/SAFE/MINIMAL/CUSTOM)

### Step 6: Cleanup
- Removes unnecessary packages
- Cleans package cache
- Optionally removes old kernels

### Step 7: Post-upgrade Verification
- Checks Debian version
- Detects broken packages
- Attempts automatic fixes
- Lists any held upgrades
- Saves post-upgrade package list

## 🎨 Upgrade Mode Comparison

| Mode | Speed | Safety | User Input | Best For |
|------|-------|--------|------------|----------|
| AUTO | ⚡⚡⚡ | ⭐⭐ | None | Scripts, experienced users |
| FULL | ⚡⚡ | ⭐⭐⭐ | Minimal | Most users |
| SAFE | ⚡ | ⭐⭐⭐⭐⭐ | Minimal | Critical systems |
| MINIMAL | ⚡⚡ | ⭐⭐⭐⭐ | None | First step only |
| CUSTOM | ⚡ | ⭐⭐⭐⭐ | Maximum | Advanced users |

## 🔧 Post-Upgrade Steps

### 1. Verify Debian Version
```bash
cat /etc/debian_version
# Should show: trixie/sid or 13.x

lsb_release -a
# Should show: Codename: trixie
```

### 2. Check System Status
```bash
# Check for failed services
systemctl --failed

# Check for broken packages
dpkg -l | grep ^..r

# Fix broken packages if any
sudo apt --fix-broken install
```

### 3. Update Additional Software

#### Flatpak
```bash
flatpak update
```

#### Snap
```bash
snap refresh
```

#### Docker
```bash
# Docker should work fine, but verify:
docker --version
docker ps
```

### 4. Check Network Configuration
```bash
# Test network connectivity
ping -c 3 google.com

# Check interfaces
ip addr

# Check DNS
cat /etc/resolv.conf
```

### 5. Reinstall Proprietary Drivers (if needed)

#### NVIDIA
```bash
# Check if NVIDIA driver needs reinstallation
nvidia-smi

# If not working, reinstall:
sudo apt install nvidia-driver
```

#### AMD
```bash
# Usually works out of the box, but check:
glxinfo | grep "OpenGL renderer"
```

## 🐛 Troubleshooting

### Issue: APT Errors After Upgrade

**Solution:**
```bash
# Fix broken dependencies
sudo apt --fix-broken install

# Update package lists
sudo apt update

# Try upgrade again
sudo apt full-upgrade
```

### Issue: Desktop Environment Missing

**Solution:**
```bash
# For GNOME
sudo apt install task-gnome-desktop

# For KDE
sudo apt install task-kde-desktop

# For XFCE
sudo apt install task-xfce-desktop
```

### Issue: Network Not Working

**Solution:**
```bash
# Restore network configuration from backup
sudo cp /path/to/backup/network/* /etc/network/

# Restart networking
sudo systemctl restart networking

# Or use NetworkManager
sudo systemctl restart NetworkManager
```

### Issue: Third-Party Software Broken

**Solution:**
```bash
# Check which repos are causing issues
sudo apt update

# Temporarily disable problematic repo
sudo mv /etc/apt/sources.list.d/problematic.list \
       /etc/apt/sources.list.d/problematic.list.disabled

# Update again
sudo apt update
```

### Issue: Held Packages

**Solution:**
```bash
# List held packages
apt-mark showhold

# Unhold a package
sudo apt-mark unhold package-name

# Try upgrade again
sudo apt full-upgrade
```

## 💾 Backup and Recovery

### Manual Backup Before Upgrade
```bash
# Backup /home directory
sudo tar -czf /mnt/external/home_backup.tar.gz /home/

# Backup databases
sudo mysqldump -u root -p --all-databases > /mnt/external/mysql_backup.sql

# Backup web files
sudo tar -czf /mnt/external/var_www.tar.gz /var/www/
```

### Restore from Backup (if needed)
```bash
# Restore sources.list to Bookworm
sudo cp /path/to/backup/sources.list /etc/apt/sources.list
sudo apt update

# Attempt to downgrade (NOT OFFICIALLY SUPPORTED)
# Better to restore from system backup
```

## 📊 Script Output Examples

### Successful Run
```
==========================================
 Debian Bookworm to Trixie Upgrade
 Version 2.0
==========================================

[INFO] Running pre-flight checks...
[SUCCESS] Pre-flight checks completed

[INFO] Creating backup directory: /home/zeus/Documents/system_backup_20250101_120000
[SUCCESS] Backup completed

[INFO] Updating current Bookworm system to latest packages...
[SUCCESS] Bookworm system updated to latest packages

[INFO] Updating repository configuration from Bookworm to Trixie...
[SUCCESS] Repository configuration updated to Trixie

Select upgrade mode:
  1) AUTO
  2) FULL
  3) SAFE (recommended)

[INFO] Performing SAFE upgrade (two-step process)...
[SUCCESS] Safe two-step upgrade completed

[SUCCESS] Your system has been upgraded to Debian Trixie
```

## ⚠️ Important Notes

### About Trixie
- Trixie is now **Debian 13 Stable** (released August 9, 2025)
- Fully supported and recommended for production use
- Receives security updates and official Debian support

### Upgrade Path
- **Supported:** Debian 12 (Bookworm) → Debian 13 (Trixie)
- **NOT Supported:** Debian 11 (Bullseye) → Debian 13 (Trixie) directly
- If on Debian 11, upgrade to 12 first, then to 13

### Third-Party Repositories
- The script **preserves** third-party repos but doesn't update them
- You may need to manually update third-party repo URLs
- Check if repos support Trixie before upgrading

### Remote Servers
- **NOT recommended** without console access
- If you must upgrade remotely:
  - Use screen or tmux
  - Have backup access method (IPMI, KVM)
  - Consider scheduled maintenance window

## 📝 License

This script is provided as-is for Debian system administration.
Use at your own risk. Always backup important data.

## 🤝 Contributing

Improvements and bug fixes welcome!

## 📚 References

- [Official Debian Trixie Release Notes](https://www.debian.org/releases/trixie/)
- [Debian Upgrade Documentation](https://www.debian.org/releases/trixie/release-notes/upgrading.html)
- [APT Package Management](https://www.debian.org/doc/manuals/apt-guide/)

## 💡 Tips

### Before Upgrade
1. ✅ Read the official Debian release notes
2. ✅ Backup all important data
3. ✅ Test in a VM or non-critical system first
4. ✅ Schedule during maintenance window
5. ✅ Ensure stable internet connection
6. ✅ Have console access ready

### During Upgrade
1. ✅ Don't interrupt the process
2. ✅ Monitor for errors in real-time
3. ✅ Read configuration file prompts carefully
4. ✅ Keep existing configs when in doubt

### After Upgrade
1. ✅ Reboot immediately
2. ✅ Verify all services are running
3. ✅ Test critical applications
4. ✅ Check logs for errors
5. ✅ Update third-party software
6. ✅ Keep backup for 30 days

---

**Last Updated:** November 2025  
**Script Version:** 2.0  
**Tested On:** Debian 12.x (Bookworm) → Debian 13 (Trixie)
