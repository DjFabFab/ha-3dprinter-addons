#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# =============================================================================
# migrate_octoprint_data.sh — split-venv data migration (plan T3).
#
# Moves user plugins out of the legacy persistent venv (/data/python/octoprint)
# into a user-site tree (PYTHONUSERBASE, e.g. /data/plugins) while the OctoPrint
# base itself is baked into the image (/opt/octoprint, installed with
# pip install --target so PIP_USER user-site installs keep working).
#
# Contract (see .omo/plans/octoprint-split-venv.md Task 3):
#   Env overrides honoured: LEGACY_DIR PYTHONUSERBASE MANIFEST PYVERSION_STAMP
#     MIGRATION_MARKER REPORT PY PIP_BIN
#   Functions: user_site_dir legacy_site_dirs discover_plugins freeze_legacy
#     has_c_ext install_spec migrate_legacy ensure_user_plugins
#   main() is guarded so sourcing this file has no side effects.
# =============================================================================

set -uo pipefail

: "${LEGACY_DIR:=/data/python/octoprint}"
: "${PYTHONUSERBASE:=/data/plugins}"
export PYTHONUSERBASE
: "${MANIFEST:=${PYTHONUSERBASE}/.octoprint-migrate-manifest.txt}"
: "${PYVERSION_STAMP:=${PYTHONUSERBASE}/.octoprint-python-version}"
: "${MIGRATION_MARKER:=${PYTHONUSERBASE}/.octoprint-legacy-migrated}"
: "${REPORT:=${PYTHONUSERBASE}/migration-report.txt}"
: "${PY:=${LEGACY_DIR}/bin/python}"
: "${PIP_BIN:=pip3}"

# --- logging ---------------------------------------------------------------

log_report() {
    mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$REPORT" 2>/dev/null || true
}

notice() {
    printf '%s\n' "$*" >&2
    log_report "$*"
}

# --- paths -----------------------------------------------------------------

# Resolve the user-site directory via the interpreter (no hardcoded version).
user_site_dir() {
    PYTHONUSERBASE="$PYTHONUSERBASE" python3 -c 'import site; print(site.getusersitepackages())'
}

# All site-packages dirs of the legacy venv (any interpreter version).
legacy_site_dirs() {
    local d
    for d in "$LEGACY_DIR"/lib/python*/site-packages; do
        if [ -d "$d" ]; then
            printf '%s\n' "$d"
        fi
    done
}

# --- dist-info helpers -------------------------------------------------------

_dist_meta() {
    sed -n "s/^$2: //p" "$1/METADATA" 2>/dev/null | head -n 1 | tr -d '\r'
}

_has_plugin_entry() {
    [ -f "$1/entry_points.txt" ] \
        && grep -q '^\[octoprint\.plugin\]' "$1/entry_points.txt" 2>/dev/null
}

_is_core() {
    [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = "octoprint" ]
}

# True when the dist ships compiled extensions (RECORD lists shared objects).
has_c_ext() {
    [ -f "$1/RECORD" ] && grep -q '\.so' "$1/RECORD" 2>/dev/null
}

# --- discovery ---------------------------------------------------------------

# Print "Name==Version" (sorted) for every legacy dist that declares an
# [octoprint.plugin] entry point, skipping the OctoPrint core itself.
discover_plugins() {
    local site_dir dist name version tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/octoprint-discover.XXXXXX")" || return 1
    for site_dir in "$LEGACY_DIR"/lib/python*/site-packages; do
        [ -d "$site_dir" ] || continue
        for dist in "$site_dir"/*.dist-info; do
            [ -d "$dist" ] || continue
            _has_plugin_entry "$dist" || continue
            name="$(_dist_meta "$dist" "Name")"
            version="$(_dist_meta "$dist" "Version")"
            if [ -z "$name" ] || [ -z "$version" ]; then
                continue
            fi
            if _is_core "$name"; then
                continue
            fi
            printf '%s==%s\n' "$name" "$version" >>"$tmp"
        done
    done
    LC_ALL=C sort -u "$tmp"
    rm -f "$tmp"
}

# Fast path: exact pins from the legacy interpreter. Fails (non-zero) when the
# legacy venv is broken (e.g. dangling interpreter symlink after a base-image
# Python upgrade); callers then fall back to the metadata scan.
freeze_legacy() {
    if [ -x "$PY" ] && "$PY" -m pip freeze 2>/dev/null; then
        return 0
    fi
    notice "freeze_legacy: legacy interpreter $PY unavailable; falling back to metadata scan"
    return 1
}

# --- install + manifest ------------------------------------------------------

_pip_install() {
    mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
    "$PIP_BIN" install --user "$1" >>"$REPORT" 2>&1
}

# Atomically union the specs from $1 into MANIFEST (sorted, deduplicated).
_merge_manifest() {
    local new_specs="${1:-}"
    mkdir -p "$(dirname "$MANIFEST")" || return 1
    local tmp clean
    tmp="$(mktemp "$(dirname "$MANIFEST")/.manifest.XXXXXX")" || return 1
    clean="${tmp}.clean"
    {
        if [ -f "$MANIFEST" ]; then cat "$MANIFEST"; fi
        if [ -n "$new_specs" ] && [ -f "$new_specs" ]; then cat "$new_specs"; fi
    } >"$tmp" 2>/dev/null
    grep -v '^[[:space:]]*$' "$tmp" >"$clean" || true
    LC_ALL=C sort -u "$clean" -o "$tmp"
    rm -f "$clean"
    mv -f "$tmp" "$MANIFEST"
}

# Install one spec with --user; on pinned failure retry unpinned. The spec is
# always recorded in MANIFEST (retry source); failures are logged to REPORT.
install_spec() {
    local spec="${1:-}"
    if [ -z "$spec" ]; then
        notice "install_spec: empty spec"
        return 1
    fi
    mkdir -p "$(dirname "$MANIFEST")" "$(dirname "$REPORT")" || return 1
    local name="${spec%%==*}"
    local installed="$spec" ok=0
    if _pip_install "$spec"; then
        ok=1
    elif [ "$name" != "$spec" ] && _pip_install "$name"; then
        installed="$name"
        ok=1
    fi
    if [ "$ok" -eq 1 ]; then
        log_report "install_spec: installed $installed"
    else
        log_report "install_spec: pip install failed for $spec (recorded for later retry)"
    fi
    local specs_tmp
    specs_tmp="$(mktemp "$(dirname "$MANIFEST")/.spec.XXXXXX")" || return 1
    printf '%s\n' "$installed" >"$specs_tmp"
    _merge_manifest "$specs_tmp"
    rm -f "$specs_tmp"
    [ "$ok" -eq 1 ]
}

# --- migration ---------------------------------------------------------------

# One-shot move of the legacy venv's plugins into the user site. Skips when
# there is nothing to do (no legacy dir) or when already done (marker).
migrate_legacy() {
    if [ -f "$MIGRATION_MARKER" ]; then
        return 0
    fi
    if [ ! -d "$LEGACY_DIR" ]; then
        log_report "migrate_legacy: no legacy dir $LEGACY_DIR; nothing to do"
        return 0
    fi
    case "$LEGACY_DIR" in
        ""|/) notice "migrate_legacy: refusing to remove $LEGACY_DIR"; return 1 ;;
    esac
    local specs_tmp
    specs_tmp="$(mktemp "${TMPDIR:-/tmp}/octoprint-specs.XXXXXX")" || return 1
    if freeze_legacy >"$specs_tmp" 2>/dev/null; then
        grep -viE '^octoprint==' "$specs_tmp" | grep -v '^[[:space:]]*$' >"${specs_tmp}.f" || true
        mv -f "${specs_tmp}.f" "$specs_tmp"
        log_report "migrate_legacy: collected specs via pip freeze"
    else
        log_report "migrate_legacy: pip freeze unavailable; using metadata scan"
        discover_plugins >"$specs_tmp" 2>/dev/null || true
    fi
    local spec
    while IFS= read -r spec || [ -n "$spec" ]; do
        case "$spec" in
            ''|\#*) continue ;;
        esac
        install_spec "$spec" || log_report "migrate_legacy: install failed for $spec (kept in manifest)"
    done <"$specs_tmp"
    _merge_manifest "$specs_tmp"
    rm -f "$specs_tmp"
    rm -rf "$LEGACY_DIR"
    mkdir -p "$(dirname "$MIGRATION_MARKER")"
    touch "$MIGRATION_MARKER"
    log_report "migrate_legacy: migration complete; removed $LEGACY_DIR"
    return 0
}

# --- user-site maintenance -----------------------------------------------------

_current_py_version() {
    python3 -c 'import sys; print("{0}.{1}".format(sys.version_info.major, sys.version_info.minor))'
}

# Union the dists currently installed in the user site into MANIFEST so
# plugins installed at runtime (e.g. via the OctoPrint UI) survive rebuilds.
_refresh_manifest() {
    local site_dir dist name version fresh
    site_dir="$(user_site_dir 2>/dev/null)" || return 0
    [ -d "$site_dir" ] || return 0
    fresh="$(mktemp "${TMPDIR:-/tmp}/octoprint-refresh.XXXXXX")" || return 1
    : >"$fresh"
    for dist in "$site_dir"/*.dist-info; do
        [ -d "$dist" ] || continue
        name="$(_dist_meta "$dist" "Name")"
        version="$(_dist_meta "$dist" "Version")"
        if [ -z "$name" ] || [ -z "$version" ]; then
            continue
        fi
        printf '%s==%s\n' "$name" "$version" >>"$fresh"
        if has_c_ext "$dist"; then
            log_report "_refresh_manifest: $name ships compiled extensions"
        fi
    done
    _merge_manifest "$fresh"
    rm -f "$fresh"
}

# Reinstall the manifest when the Python minor version changed (compiled
# extensions need a rebuild), then refresh the manifest from the user site.
ensure_user_plugins() {
    local site_dir current stored
    mkdir -p "$PYTHONUSERBASE" || return 1
    site_dir="$(user_site_dir 2>/dev/null)" || site_dir=""
    if [ -n "$site_dir" ]; then
        mkdir -p "$site_dir" 2>/dev/null || true
    fi
    current="$(_current_py_version)" || return 1
    stored="$(cat "$PYVERSION_STAMP" 2>/dev/null || true)"
    if [ "$stored" != "$current" ]; then
        log_report "ensure_user_plugins: python version $stored -> $current; reinstalling manifest"
        if [ -f "$MANIFEST" ]; then
            local spec
            while IFS= read -r spec || [ -n "$spec" ]; do
                case "$spec" in
                    ''|\#*) continue ;;
                esac
                install_spec "$spec" || log_report "ensure_user_plugins: reinstall failed for $spec"
            done <"$MANIFEST"
        fi
        local stamp_tmp
        stamp_tmp="$(mktemp "$(dirname "$PYVERSION_STAMP")/.stamp.XXXXXX")" || return 1
        printf '%s\n' "$current" >"$stamp_tmp"
        mv -f "$stamp_tmp" "$PYVERSION_STAMP"
    fi
    _refresh_manifest
}

# --- entrypoint -----------------------------------------------------------------

main() {
    mkdir -p "$PYTHONUSERBASE" || return 1
    migrate_legacy || log_report "main: migrate_legacy reported issues"
    ensure_user_plugins || log_report "main: ensure_user_plugins reported issues"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
