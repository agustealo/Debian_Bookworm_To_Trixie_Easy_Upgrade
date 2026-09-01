#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../debian-bookworm-to-trixie.sh
source "$ROOT/debian-bookworm-to-trixie.sh"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains(){ grep -Fq "$2" "$1" || fail "$1 missing: $2"; }
assert_not_contains(){ ! grep -Fq "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bookworm.list" <<'EOF'
deb https://deb.debian.org/debian bookworm main contrib non-free-firmware
deb https://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
# deb https://deb.debian.org/debian bookworm-backports main
EOF
rewrite_list_file "$tmp/bookworm.list" "$tmp/trixie.list"
assert_contains "$tmp/trixie.list" "trixie main"
assert_contains "$tmp/trixie.list" "trixie-updates"
assert_contains "$tmp/trixie.list" "trixie-security"
assert_contains "$tmp/trixie.list" "# deb https://deb.debian.org/debian bookworm-backports main"
assert_not_contains "$tmp/trixie.list" "deb https://deb.debian.org/debian bookworm main"

cat > "$tmp/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rewrite_sources_file "$tmp/debian.sources" "$tmp/trixie.sources"
assert_contains "$tmp/trixie.sources" "Suites: trixie trixie-updates"
assert_contains "$tmp/trixie.sources" "Suites: trixie-security"
assert_not_contains "$tmp/trixie.sources" "Suites: bookworm"

mkdir -p "$tmp/apt/sources.list.d" "$tmp/apt/mirrors"
cp "$tmp/bookworm.list" "$tmp/apt/sources.list"
cat > "$tmp/apt/sources.list.d/vendor.list" <<'EOF'
deb https://packages.example.invalid/debian stable main
EOF
APT_ROOT="$tmp/apt"
inventory_sources
[[ ${#DEBIAN_FILES[@]} -eq 1 ]] || fail "expected one Debian source file"
[[ ${#THIRD_PARTY_FILES[@]} -eq 1 ]] || fail "expected one third-party source file"

cat > "$tmp/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian bookworm main
deb https://packages.example.invalid/debian stable main
EOF
if ( inventory_sources >/dev/null 2>&1 ); then
  fail "mixed official and third-party .list should fail closed"
fi

rm -f "$tmp/apt/sources.list" "$tmp/apt/sources.list.d/vendor.list"
cat > "$tmp/apt/mirrors/debian.list" <<'EOF'
https://deb.debian.org/debian
EOF
cat > "$tmp/apt/mirrors/debian-security.list" <<'EOF'
https://security.debian.org/debian-security
EOF
cat > "$tmp/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/mirrors/debian.list
Suites: bookworm bookworm-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: mirror+file:///etc/apt/mirrors/debian-security.list
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
inventory_sources
[[ ${#DEBIAN_FILES[@]} -eq 1 ]] || fail "cloud mirror deb822 source should classify as Debian"
[[ ${#THIRD_PARTY_FILES[@]} -eq 0 ]] || fail "cloud mirror deb822 source should not classify as third-party"
rewrite_sources_file "$tmp/apt/sources.list.d/debian.sources" "$tmp/cloud-trixie.sources"
assert_contains "$tmp/cloud-trixie.sources" "Suites: trixie trixie-updates"
assert_contains "$tmp/cloud-trixie.sources" "Suites: trixie-security"

cat > "$tmp/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: bookworm
Components: main

Types: deb
URIs: https://packages.example.invalid/debian
Suites: stable
Components: main
EOF
if ( inventory_sources >/dev/null 2>&1 ); then
  fail "mixed Debian/vendor deb822 file should fail closed"
fi

cat > "$tmp/apt/mirrors/debian.list" <<'EOF'
https://deb.debian.org/debian
https://packages.example.invalid/debian
EOF
cat > "$tmp/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/mirrors/debian.list
Suites: bookworm
Components: main
EOF
if ( inventory_sources >/dev/null 2>&1 ); then
  fail "mixed cloud mirror target should fail closed"
fi

cat > "$tmp/apt/mirrors/debian.list" <<'EOF'
https://deb.debian.org/debian
EOF
cat > "$tmp/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/mirrors/missing.list
Suites: bookworm
Components: main
EOF
if ( inventory_sources >/dev/null 2>&1 ); then
  fail "missing cloud mirror target should not be trusted as Debian"
fi

printf 'PASS: source migration and ownership fixtures\n'
