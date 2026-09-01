# Debian Bookworm to Trixie Upgrade Safety Tool

A defensive Bash utility for upgrading a supported Debian 12 (Bookworm) system to Debian 13 (Trixie).

This project deliberately fails closed when the machine is not a clean Debian 12 system, when package state is inconsistent, when official and third-party repositories are mixed in one source file, or when migrated Trixie repositories cannot be validated.

## Safety model

The tool:

- validates `/etc/os-release` before doing upgrade work;
- checks `dpkg` and APT package health;
- checks free space on `/`, `/var`, and `/boot`;
- supports both classic `.list` and deb822 `.sources` repository formats;
- inventories official and third-party repositories separately;
- disables separate third-party source files by default during the release transition;
- refuses ambiguous mixed official/third-party `.list` files;
- creates a root-owned backup under `/var/backups/debian-bookworm-to-trixie` by default;
- validates migrated Trixie repositories with `apt-get update` before package upgrade;
- restores the original source configuration if migrated repository validation fails;
- simulates the full upgrade before the final package transition;
- verifies Debian 13 / `trixie` and package consistency before reporting success;
- does not automatically purge old kernels.

A system upgrade can never be made risk-free. Back up important data and ensure you have a recovery path before proceeding.

## Usage

```bash
chmod +x debian-bookworm-to-trixie.sh
sudo ./debian-bookworm-to-trixie.sh
```

Start with the non-mutating preview:

```bash
sudo ./debian-bookworm-to-trixie.sh --dry-run
```

Useful options:

```text
--dry-run             Validate and preview without changing system state
--non-interactive     Never prompt; fail closed where confirmation is required
--yes                 Assume yes for confirmations
--backup-dir PATH     Select the backup root directory
--allow-third-party   Keep third-party APT sources enabled during migration
--no-reboot           Never offer to reboot
-h, --help            Show help
```

`--allow-third-party` deliberately weakens the default safety posture. Use it only when you have independently verified that every enabled external repository supports Debian 13 Trixie.

## Upgrade sequence

1. Validate platform, commands, package database and filesystem space.
2. Inventory APT source files.
3. Verify current Bookworm repositories with APT itself rather than ICMP/ping.
4. Back up APT configuration and package state.
5. Fully refresh the current Bookworm installation.
6. Rewrite official Debian Bookworm suites to their Trixie equivalents.
7. Disable separate third-party source files unless explicitly allowed.
8. Run `apt-get update` against the migrated repository configuration.
9. Roll back APT sources if migrated repository validation fails.
10. Simulate `apt-get full-upgrade`.
11. Perform the Trixie package upgrade.
12. Verify `/etc/os-release`, `dpkg --audit`, and `apt-get check` before reporting success.

## Development and smoke tests

The repository includes a GitHub Actions quality gate covering Bash syntax, ShellCheck, fixture tests for classic and deb822 source migration, mixed-source fail-closed behavior, and the command-line help surface.

Run locally:

```bash
bash -n debian-bookworm-to-trixie.sh
bash -n tests/test-source-migration.sh
shellcheck debian-bookworm-to-trixie.sh tests/test-source-migration.sh
bash tests/test-source-migration.sh
```

## Scope

This tool targets direct upgrades from Debian 12 Bookworm to Debian 13 Trixie. It intentionally rejects already-upgraded systems and non-Debian distributions. Complex installations with unusual APT pinning, mixed distributions, custom boot layouts, unsupported external repositories, or incomplete package transactions should be repaired or normalized before using the upgrader.
