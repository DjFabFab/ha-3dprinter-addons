#!/usr/bin/env bash
# TDD red: discover_plugins()
# Must scan lib/python*/site-packages under $LEGACY_DIR, keep only dists that
# declare an [octoprint.plugin] entry point, read Name/Version from METADATA,
# skip the OctoPrint core, and print "Name==Version" sorted.
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
make_legacy_venv "$LEGACY_DIR"

got="$(discover_plugins 2>/dev/null || true)"
expected=$'OctoPrint-Bar==0.9.0\nOctoPrint-Foo==1.2.3'

assert_eq "$expected" "$got" "discover_plugins lists the two plugins, sorted"
assert_not_contains "$got" "OctoPrint==" "OctoPrint core is skipped"
assert_not_contains "$got" "requests==" "requests dependency is filtered (no plugin entry point)"

test_summary
