#!/usr/bin/env bash
# =============================================================================
# Shared fixtures + assertions for the OctoPrint split-venv migration suite.
#
# TDD: these tests stay RED until rootfs/scripts/migrate_octoprint_data.sh (plan
# T3) provides the documented functions. See .omo/plans/octoprint-split-venv.md.
#
# Contract under test:
#   Env overrides honoured by the migration script:
#     LEGACY_DIR PYTHONUSERBASE MANIFEST PYVERSION_STAMP
#     MIGRATION_MARKER REPORT PY PIP_BIN
#   Functions exposed by the migration script:
#     user_site_dir discover_plugins freeze_legacy install_spec
#     migrate_legacy ensure_user_plugins
#   main() is guarded, so sourcing the script has no side effects.
# =============================================================================

set -uo pipefail

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$FIXTURES_DIR/.." && pwd)"
ADDON_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export TESTS_DIR ADDON_DIR

# Path to the script under test. Accepts both env spellings, defaults to the
# real repo path (not an absolute /rootfs path) so it works without a container.
MIGRATE_SCRIPT="${MIGRATE_SCRIPT:-${MIGRATION_SCRIPT:-$ADDON_DIR/rootfs/scripts/migrate_octoprint_data.sh}}"
MIGRATION_SCRIPT="$MIGRATE_SCRIPT"
export MIGRATE_SCRIPT MIGRATION_SCRIPT

# --- assertions (TAP-like) ---------------------------------------------------
TESTS_RUN=0
TESTS_FAILED=0

_ok()    { TESTS_RUN=$((TESTS_RUN + 1)); printf 'ok %d - %s\n' "$TESTS_RUN" "$1"; }
_notok() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf 'not ok %d - %s\n' "$TESTS_RUN" "$1"; }

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [ "$expected" = "$actual" ]; then
        _ok "$msg"
    else
        _notok "$msg (expected [$expected], got [$actual])"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _ok "$msg" ;;
        *)           _notok "$msg (missing [$needle] in [$haystack])" ;;
    esac
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) _notok "$msg (unexpected [$needle])" ;;
        *)           _ok "$msg" ;;
    esac
}

assert_file_exists() { if [ -f "$1" ]; then _ok "$2"; else _notok "$2 (missing file: $1)"; fi; }
assert_dir_absent()  { if [ ! -d "$1" ]; then _ok "$2"; else _notok "$2 (still present: $1)"; fi; }

test_summary() {
    printf '# %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}

# Load the script under test (main is guarded). Returns non-zero -> RED.
load_migration() {
    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        printf 'diagnostic: script under test not found: %s\n' "$MIGRATE_SCRIPT" >&2
        return 1
    fi
    # The add-on script is #!/usr/bin/with-contenv bashio and calls bashio::*.
    # Shim the helpers so it can be sourced on a plain host.
    bashio::log.trace()   { :; }
    bashio::log.debug()   { :; }
    bashio::log.info()    { :; }
    bashio::log.notice()  { :; }
    bashio::log.warning() { :; }
    bashio::log.error()   { :; }
    bashio::log.fatal()   { return 1; }
    bashio::exit.nok()    { return 1; }
    bashio::exit.ok()     { return 0; }
    bashio::config()      { :; }
    # shellcheck disable=SC1090
    source "$MIGRATE_SCRIPT"
    # The script may enable errexit/nounset; keep the harness tolerant so the
    # negative assertions below control the outcome.
    set +e
    return 0
}

# --- sandbox -----------------------------------------------------------------
# Builds an isolated directory tree and points every contract env override at
# it, so tests never touch real /data paths.
sandbox_init() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/octoprint-migrate.XXXXXX")"
    export SANDBOX
    export LEGACY_DIR="$SANDBOX/data/python/octoprint"
    export PYTHONUSERBASE="$SANDBOX/data/plugins"
    export MANIFEST="$PYTHONUSERBASE/.octoprint-migrate-manifest.txt"
    export PYVERSION_STAMP="$PYTHONUSERBASE/.octoprint-python-version"
    export MIGRATION_MARKER="$PYTHONUSERBASE/.octoprint-legacy-migrated"
    export REPORT="$PYTHONUSERBASE/migration-report.txt"
    # PY = the *current* runtime interpreter (resolves the user site / version).
    # The legacy interpreter is only ever reached inside freeze_legacy() via
    # $LEGACY_DIR/bin/python, which stays dangling by design.
    export PY="${RUNTIME_PY:-$(command -v python3)}"
    export PIP_BIN="$SANDBOX/bin/pip-logger"
    export PIP_LOG="$SANDBOX/pip.log"
    mkdir -p "$LEGACY_DIR/bin" "$PYTHONUSERBASE" "$SANDBOX/bin"
    : > "$PIP_LOG"
    make_pip_logger "$PIP_BIN"
}

sandbox_cleanup() {
    if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}

# A fake pip that records each invocation (argv joined by spaces) into $PIP_LOG.
make_pip_logger() {
    local path="$1"
    cat > "$path" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PIP_LOG:?PIP_LOG unset}"
exit 0
EOS
    chmod +x "$path"
}

# --- dist + venv builders ----------------------------------------------------
# make_dist <site_dir> <name> <version> [plugin|no-plugin]
# Writes a minimal PEP 376 .dist-info tree. Only "plugin" dists carry the
# [octoprint.plugin] entry point that discover_plugins must require.
make_dist() {
    local site_dir="$1" name="$2" version="$3" kind="${4:-plugin}"
    local norm dist
    norm="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
    dist="$site_dir/${norm}-${version}.dist-info"
    mkdir -p "$dist"

    cat > "$dist/METADATA" <<EOF
Metadata-Version: 2.1
Name: ${name}
Version: ${version}
EOF

    if [ "$kind" = "plugin" ]; then
        cat > "$dist/entry_points.txt" <<EOF
[octoprint.plugin]
${norm} = ${norm}:Plugin

[console_scripts]
${norm} = ${norm}:main
EOF
    fi

    cat > "$dist/RECORD" <<EOF
${norm}/__init__.py,,
${norm}-${version}.dist-info/METADATA,,
${norm}-${version}.dist-info/RECORD,,
EOF
}

# make_legacy_venv [legacy_dir]
# Models the post-upgrade /data/python/octoprint: a python3.9-era venv whose
# interpreter symlinks now dangle. Contains OctoPrint 1.11.4 core (must be
# filtered), two user plugins, and the requests dependency (no plugin entry
# point, must be filtered).
make_legacy_venv() {
    local legacy="${1:-$LEGACY_DIR}"
    local site="$legacy/lib/python3.9/site-packages"
    mkdir -p "$legacy/bin" "$site"

    # Dangling interpreter/console scripts -> "pip freeze" cannot run.
    ln -sfn /nonexistent/python3.9 "$legacy/bin/python"
    ln -sfn /nonexistent/python3.9 "$legacy/bin/python3"
    ln -sfn /nonexistent/python3.9 "$legacy/bin/python3.9"
    ln -sfn /nonexistent/python3.9 "$legacy/bin/pip"

    # Core: carries a [octoprint.plugin] entry point on purpose, so discovering
    # it can only be excluded by matching the OctoPrint core name.
    make_dist "$site" "OctoPrint"     "1.11.4" plugin
    make_dist "$site" "OctoPrint-Foo" "1.2.3"  plugin
    make_dist "$site" "OctoPrint-Bar" "0.9.0"  plugin
    make_dist "$site" "requests"      "2.31.0" no-plugin

    cat > "$legacy/pyvenv.cfg" <<EOF
home = ${legacy}/bin
version = 3.9.2
EOF
}
