#!/usr/bin/env bash
# TDD red: user_site_dir() resolution + version-literal guard.
# user_site_dir() must resolve the user-site directory via
# site.getusersitepackages() for the running interpreter (PYTHONUSERBASE
# driven), so it works on any Python minor. The migration script must NOT
# bake in a hardcoded pythonX.Y site-packages literal.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixtures.sh
source "$HERE/lib/fixtures.sh"

if ! load_migration; then
    _notok "script under test exists ($MIGRATE_SCRIPT)"
    test_summary
    exit 1
fi

sandbox_init
trap sandbox_cleanup EXIT

got="$(user_site_dir 2>/dev/null || true)"
expected="$(PYTHONUSERBASE="$PYTHONUSERBASE" python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null || true)"

assert_eq "$expected" "$got" "user_site_dir resolves via site.getusersitepackages()"
assert_contains "$got" "$PYTHONUSERBASE" "user_site_dir honours PYTHONUSERBASE"

# Guard: no hardcoded pythonX.Y site-packages literal in the script under test.
# The version must be derived from the running interpreter at runtime.
hardcoded="$(grep -nE 'python3\.[0-9]+' "$MIGRATE_SCRIPT" 2>/dev/null || true)"
if [ -z "$hardcoded" ]; then
    _ok "no hardcoded pythonX.Y site-packages literal in migration script"
else
    _notok "no hardcoded pythonX.Y site-packages literal in migration script (found: $hardcoded)"
fi

test_summary
