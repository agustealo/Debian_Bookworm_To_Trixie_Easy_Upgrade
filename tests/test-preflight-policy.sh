#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../debian-bookworm-to-trixie.sh
source "$ROOT/debian-bookworm-to-trixie.sh"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_policy_fail(){
    local description=$1
    if ( check_upgrade_policy >/dev/null 2>&1 ); then
        fail "$description should fail closed"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/apt/sources.list.d" "$tmp/apt/preferences.d"
APT_ROOT="$tmp/apt"

cat > "$APT_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
EOF

# Runtime overrides exercise policy branches; ShellCheck cannot see indirect calls.
# shellcheck disable=SC2317
list_held_packages(){ return 0; }
check_upgrade_policy

# shellcheck disable=SC2317
list_held_packages(){ printf 'linux-image-amd64\n'; }
expect_policy_fail "held package"
# shellcheck disable=SC2317
list_held_packages(){ return 0; }

cat > "$APT_ROOT/preferences.d/50-testing.pref" <<'EOF'
Package: *
Pin: release a=testing
Pin-Priority: 100
EOF
expect_policy_fail "active APT pinning"
rm -f "$APT_ROOT/preferences.d/50-testing.pref"

cat > "$APT_ROOT/preferences.d/ignored.txt" <<'EOF'
Package: *
Pin: release a=testing
Pin-Priority: 100
EOF
check_upgrade_policy
rm -f "$APT_ROOT/preferences.d/ignored.txt"

cat > "$APT_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-proposed-updates
Components: main
EOF
expect_policy_fail "proposed-updates"

cat > "$APT_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-backports
Components: main
EOF
expect_policy_fail "regular backports"

cat > "$APT_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-backports-sloppy
Components: main
EOF
expect_policy_fail "sloppy backports"

cat > "$APT_ROOT/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
EOF
check_upgrade_policy

printf 'PASS: release preflight policy fixtures\n'
