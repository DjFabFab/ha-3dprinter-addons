#!/usr/bin/env bash
# =============================================================================
# Test runner for the OctoPrint split-venv migration (TDD red).
#
# Every tests/test_*.sh is expected to FAIL until
# rootfs/scripts/migrate_octoprint_data.sh (plan T3) exists and implements the
# documented contract. A red run is the expected state during TDD.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/fixtures.sh
source "$HERE/lib/fixtures.sh"

suites=0
failed=0

for t in "$HERE"/test_*.sh; do
    [ -f "$t" ] || continue
    suites=$((suites + 1))
    name="$(basename "$t")"
    printf '\n========================================\n>>> %s\n========================================\n' "$name"
    if MIGRATE_SCRIPT="$MIGRATE_SCRIPT" bash "$t"; then
        printf '>>> %s: GREEN\n' "$name"
    else
        printf '>>> %s: RED\n' "$name"
        failed=$((failed + 1))
    fi
done

printf '\n========================================\n'
printf 'suites=%d failed=%d\n' "$suites" "$failed"
printf 'script under test: %s\n' "$MIGRATE_SCRIPT"
printf '========================================\n'

if [ "$failed" -gt 0 ]; then
    printf 'RED: split-venv migration not implemented yet (expected during TDD).\n'
    exit 1
fi

printf 'GREEN: all suites passed.\n'
exit 0
