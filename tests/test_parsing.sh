#!/usr/bin/env bash
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$WORKDIR/autosecure.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_eq() {
  local expected="$1"
  local got="$2"
  local name="$3"
  if [ "$expected" != "$got" ]; then
    printf 'FAIL: %s\nExpected:\n%s\nGot:\n%s\n' "$name" "$expected" "$got"
    exit 1
  fi
  printf 'PASS: %s\n' "$name"
}

cat > "$tmpdir/static.txt" <<'DATA'
# comment
; semi-comment

1.2.3.4 note
5.6.7.8
1.2.3.4 duplicate
DATA

cat > "$tmpdir/dshield.txt" <<'DATA'
# header
1.2.3.0 x 24
9.9.9.0 y 24
1.2.3.0 z 24
bad line
DATA

static_got="$(_parse_static_blocklist_file "$tmpdir/static.txt")"
static_expected=$'1.2.3.4\n5.6.7.8'
assert_eq "$static_expected" "$static_got" "static blocklist parsing"

dshield_got="$(_parse_dshield_file "$tmpdir/dshield.txt")"
dshield_expected=$'1.2.3.0/24\n9.9.9.0/24'
assert_eq "$dshield_expected" "$dshield_got" "dshield range parsing"

if _is_valid_ip_or_cidr "1.2.3.4"; then
  printf 'PASS: ipv4 validation\n'
else
  printf 'FAIL: ipv4 validation\n'
  exit 1
fi

if _is_valid_ip_or_cidr "2001:db8::1/64"; then
  printf 'PASS: ipv6 validation\n'
else
  printf 'FAIL: ipv6 validation\n'
  exit 1
fi

if _is_valid_ip_or_cidr "not-an-ip"; then
  printf 'FAIL: invalid ip rejection\n'
  exit 1
else
  printf 'PASS: invalid ip rejection\n'
fi

if _ip_matches_family v4 "1.2.3.4" && ! _ip_matches_family v4 "2001:db8::1"; then
  printf 'PASS: family match v4\n'
else
  printf 'FAIL: family match v4\n'
  exit 1
fi

if _ip_matches_family v6 "2001:db8::1" && ! _ip_matches_family v6 "1.2.3.4"; then
  printf 'PASS: family match v6\n'
else
  printf 'FAIL: family match v6\n'
  exit 1
fi

ipset_v4_name="$(_ipset_set_name v4)"
assert_eq "AutosecureV4" "$ipset_v4_name" "ipset v4 name"

ipset_v6_name="$(_ipset_set_name v6)"
assert_eq "AutosecureV6" "$ipset_v6_name" "ipset v6 name"

printf 'All tests passed.\n'
