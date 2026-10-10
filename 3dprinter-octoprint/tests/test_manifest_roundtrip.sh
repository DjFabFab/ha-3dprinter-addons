#!/usr/bin/env bash
# TDD red: manifest roundtrip + migration lifecycle.
# install_spec() installs a spec via pip --user and logs to REPORT.
# migrate_legacy() merges discovered plugin specs into MANIFEST atomically
#   (without clobbering existing entries), writes the migration marker,
#   removes LEGACY_DIR, and is idempotent once the marker exists.
# ensure_user_plugins() refreshes PYVERSION_STAMP and reinstalls the manifest
#   when the Python major.minor changed.
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

# Reset mutable migration state between scenarios (keeps the fake pip/logger).
reset_state() {
    rm -rf "$LEGACY_DIR" "$MIGRATION_MARKER" "$MANIFEST" "$PYVERSION_STAMP" "$REPORT" 2>/dev/null || true
    mkdir -p "$LEGACY_DIR/bin" "$PYTHONUSERBASE"
    : > "$PIP_LOG"
}

# --- install_spec ------------------------------------------------------------
reset_state
install_spec "OctoPrint-Foo==1.2.3" >/dev/null 2>&1
assert_contains "$(cat "$PIP_LOG" 2>/dev/null || true)" "OctoPrint-Foo==1.2.3" \
    "install_spec invokes pip with the spec"
assert_file_exists "$REPORT" "install_spec logs to REPORT"

# --- migrate_legacy ----------------------------------------------------------
reset_state
make_legacy_venv "$LEGACY_DIR"
printf 'existing==9.9.9\n' > "$MANIFEST"
migrate_legacy >/dev/null 2>&1

manifest="$(cat "$MANIFEST" 2>/dev/null || true)"
assert_contains "$manifest" "existing==9.9.9"       "migrate_legacy preserves existing manifest entries"
assert_contains "$manifest" "OctoPrint-Foo==1.2.3"  "migrate_legacy records discovered plugin Foo"
assert_contains "$manifest" "OctoPrint-Bar==0.9.0"  "migrate_legacy records discovered plugin Bar"
assert_not_contains "$manifest" "OctoPrint=="       "migrate_legacy excludes OctoPrint core"
assert_file_exists "$MIGRATION_MARKER"              "migrate_legacy writes migration marker"
assert_dir_absent "$LEGACY_DIR"                     "migrate_legacy removes legacy venv"

# Idempotent: marker present -> second run is a no-op.
before="$(cat "$MANIFEST" 2>/dev/null || true)"
migrate_legacy >/dev/null 2>&1
after="$(cat "$MANIFEST" 2>/dev/null || true)"
assert_eq "$before" "$after" "migrate_legacy is idempotent with marker present"

# --- ensure_user_plugins -----------------------------------------------------
reset_state
printf '3.9\n' > "$PYVERSION_STAMP"
printf 'OctoPrint-Foo==1.2.3\n' > "$MANIFEST"
ensure_user_plugins >/dev/null 2>&1

stamp="$(cat "$PYVERSION_STAMP" 2>/dev/null || true)"
current="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
assert_eq "$current" "$stamp" "ensure_user_plugins refreshes PYVERSION_STAMP to current major.minor"
assert_contains "$(cat "$PIP_LOG" 2>/dev/null || true)" "OctoPrint-Foo" \
    "ensure_user_plugins reinstalls manifest specs on version change"

test_summary
