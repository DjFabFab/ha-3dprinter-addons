#!/usr/bin/env bash
# TDD red: broken legacy-venv fallback.
# The legacy venv's bin/python is a dangling symlink, so freeze_legacy() must
# fail (non-zero), and migrate_legacy() must fall back to a metadata scan,
# still producing the manifest, marker, and removing the legacy dir.
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

# Fixture sanity: the legacy interpreter must be a dangling symlink.
if [ -L "$LEGACY_DIR/bin/python" ] && [ ! -e "$LEGACY_DIR/bin/python" ]; then
    _ok "legacy bin/python is a dangling symlink"
else
    _notok "legacy bin/python is a dangling symlink"
fi

# freeze_legacy must detect the dangling interpreter and fail.
if freeze_legacy >/dev/null 2>&1; then
    _notok "freeze_legacy returns non-zero on dangling interpreter"
else
    _ok "freeze_legacy returns non-zero on dangling interpreter"
fi

# migrate_legacy must still succeed via metadata scan.
if migrate_legacy >/dev/null 2>&1; then
    _ok "migrate_legacy succeeds despite broken legacy interpreter"
else
    _notok "migrate_legacy succeeds despite broken legacy interpreter"
fi

assert_file_exists "$MANIFEST" "manifest written via metadata fallback"
manifest="$(cat "$MANIFEST" 2>/dev/null || true)"
assert_contains "$manifest" "OctoPrint-Bar==0.9.0" "manifest contains Bar from metadata scan"
assert_contains "$manifest" "OctoPrint-Foo==1.2.3" "manifest contains Foo from metadata scan"

assert_file_exists "$MIGRATION_MARKER" "migration marker written"
assert_dir_absent "$LEGACY_DIR" "legacy venv removed after migration"

# Idempotent: with the marker present a second run is a no-op.
before="$(cat "$MANIFEST" 2>/dev/null || true)"
migrate_legacy >/dev/null 2>&1
after="$(cat "$MANIFEST" 2>/dev/null || true)"
assert_eq "$before" "$after" "second migrate_legacy is a no-op (marker present)"

test_summary
