#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# apply-stealth.sh — Transform stock Frida into a stealth-renamed fork.
#
# Usage:
#   ./releng/apply-stealth.sh                              # Use default conf, cwd as target
#   ./releng/apply-stealth.sh /path/to/custom.conf         # Custom conf, cwd as target
#   ./releng/apply-stealth.sh /path/to/custom.conf /path   # Custom conf, explicit target
#
# This script is IDEMPOTENT — running it twice produces the same result.
# It transforms a clean upstream Frida checkout into the configured namespace.
#
# The script does NOT modify:
#   - Subproject directory names (frida-core/, frida-gum/, etc.)
#   - Library output filenames (libfrida-core-1.0.a, etc.)
#   - Python import name (import frida)
#   - Upstream dependency URLs (github.com/frida/glib, etc.)
#   - .wrap files (Meson subproject references)
#   - Test files
#   - Build output directories
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${1:-$SCRIPT_DIR/stealth.conf}"
REPO_ROOT="${2:-$(pwd)}"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: Config file not found: $CONF_FILE"
    echo "Usage: $0 [config_file] [target_dir]"
    echo "  config_file defaults to releng/stealth.conf next to the script"
    echo "  target_dir  defaults to current working directory"
    exit 1
fi

# shellcheck source=stealth.conf
source "$CONF_FILE"

# ─── Derived values ─────────────────────────────────────────────────────────
UP="frida"
UP_P="Frida"
UP_U="FRIDA"
UP_PORT="27042"
UP_RDNS="re.frida"
UP_SELINUX="frida_file"
UP_V8="-frida"
UP_AUTHOR="Frida Developers"
UP_EMAIL="oleavr@frida.re"
UP_URL="https://frida.re"

ST="$STEALTH_NAME"
ST_P="$STEALTH_NAME_PASCAL"
ST_U="$STEALTH_NAME_UPPER"

log() { echo "[stealth] $*"; }

# ─── Exclude filter for find ────────────────────────────────────────────────
# Prune patterns to skip node_modules, __pycache__, build, deps, .git, test dirs
PRUNE_ARGS=( -path '*/node_modules' -o -path '*/__pycache__' -o -path '*/build' -o -path '*/deps' -o -path '*/.git' -o -path '*.wrap' )

# Helper: run sed on matching files within a directory
# Usage: sed_in <dir> <name_pattern> <sed_args...>
#   name_pattern: e.g. "*.vala" or "*.c *.h *.vala *.vapi"
#
# IMPORTANT: This function MUST disable shell globbing while iterating
# $names. If the caller's CWD (or anywhere on the shell-glob expansion
# path) contains a file matching one of the patterns (e.g. test_attach.py
# matching *.py), bash will replace the wildcard with that filename BEFORE
# the find sees it. Result: silent under-coverage (find skips the actual
# matching files and only looks for the literal filename). This was the
# root cause of Bug #8: the Python binding's frida:rpc/yszint:rpc rewrite
# was skipped because *.py expanded to test_attach.py.
sed_in() {
    local dir="$1"; shift
    local names="$1"; shift

    # Build -name arguments. Disable filename globbing for this loop:
    # `set -f` prevents `*.py` etc. from being expanded by bash.
    local name_arr=()
    local first=true
    set -f
    for n in $names; do
        if $first; then
            name_arr+=( -name "$n" )
            first=false
        else
            name_arr+=( -o -name "$n" )
        fi
    done
    set +f

    [[ -d "$dir" ]] || return 0
    find "$dir" \( "${PRUNE_ARGS[@]}" \) -prune -o -type f \( "${name_arr[@]}" \) -print0 2>/dev/null | \
        xargs -0 -r sed -i "$@"
}

# Helper: run sed on specific file if it exists
sed_file() {
    local f="$REPO_ROOT/$1"; shift
    [[ -f "$f" ]] || return 0
    sed -i "$@" "$f"
}

# Helper: run sed_in only if the directory exists. Use this for releng/
# and other top-level dirs that may be absent in partial-tree test runs.
sed_in_optional() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    sed_in "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 1: Vala/C Namespace Renames
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 1: Vala/C namespace renames"

# 1a. Vala namespace and qualified references
sed_in "$REPO_ROOT/subprojects" "*.vala" \
    -e "s/namespace ${UP_P}\b/namespace ${ST_P}/g" \
    -e "s/${UP_P}\.\([A-Z]\)/${ST_P}.\1/g"
[[ -d "$REPO_ROOT/src" ]] && sed_in "$REPO_ROOT/src" "*.vala" \
    -e "s/namespace ${UP_P}\b/namespace ${ST_P}/g" \
    -e "s/${UP_P}\.\([A-Z]\)/${ST_P}.\1/g"
log "  Vala namespace declarations + qualified refs"

# 1b. GIR namespace attributes
sed_in "$REPO_ROOT/subprojects" "*.vala" \
    -e "s/gir_namespace = \"${UP_P}\"/gir_namespace = \"${ST_P}\"/g" \
    -e "s/lower_case_cprefix = \"${UP}_\"/lower_case_cprefix = \"${ST}_\"/g"
log "  GIR namespace attributes"

# 1c. C/Vala prefixes: FRIDA_ → YSZINT_, frida_ → yszint_, FridaX → YszintX
# Combine all 3 patterns into one sed call per file for speed
sed_in "$REPO_ROOT/subprojects" "*.c *.h *.vala *.vapi" \
    -e "s/${UP_U}_/${ST_U}_/g" \
    -e "s/\b${UP}_/${ST}_/g" \
    -e "s/${UP_P}\([A-Z][a-zA-Z]*\)/${ST_P}\1/g"
log "  C/Vala function and type prefixes"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 2: Protocol & Network Identifiers
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 2: Protocol & network identifiers"

# 2a. Default port (Vala + Python examples)
[[ -d "$REPO_ROOT/subprojects/frida-core" ]] && sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala" \
    -e "s/${UP_PORT}/${STEALTH_PORT}/g"
[[ -d "$REPO_ROOT/subprojects/frida-python" ]] && sed_in "$REPO_ROOT/subprojects/frida-python" "*.py" \
    -e "s/port=${UP_PORT}/port=${STEALTH_PORT}/g" \
    -e "s/port=${UP_PORT},/port=${STEALTH_PORT},/g"
log "  Port: ${UP_PORT} → ${STEALTH_PORT}"

# 2b. User-Agent / Server headers (Vala + C)
[[ -d "$REPO_ROOT/subprojects/frida-core" ]] && sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala" \
    -e "s/\"${UP_P}\//\"${ST_P}\//g" \
    -e "s/\"Server: ${UP_P}\//\"Server: ${ST_P}\//g"
# Inspector server in C (gumjs)
[[ -d "$REPO_ROOT/subprojects/frida-gum" ]] && sed_in "$REPO_ROOT/subprojects/frida-gum" "*.c" \
    -e "s/\"${UP_P}\/v/\"${ST_P}\/v/g"
log "  User-Agent / Server headers"

# 2c. D-Bus service names and bundle IDs
# Cover all file types that reference re.frida.* identifiers
for dir in subprojects/frida-core subprojects/frida-gum subprojects/frida-python subprojects/frida-tools; do
    [[ -d "$REPO_ROOT/$dir" ]] || continue
    sed_in "$REPO_ROOT/$dir" "*.vala *.xml *.h *.c *.py *.ts *.sh *.plist meson.build" \
        -e "s/${UP_RDNS}\./${STEALTH_RDNS}./g" \
        -e "s|/${UP_RDNS//./\/}/|/${STEALTH_RDNS//./\/}/|g"
done
# Also cover releng modules (guarded — releng/ may not exist in detached test runs)
if [[ -d "$REPO_ROOT/releng" ]]; then
    sed_in "$REPO_ROOT/releng" "*.json *.js" \
        -e "s/${UP_RDNS}\./${STEALTH_RDNS}./g"
else
    log "  (skip: releng/ not present at target root — partial tree)"
fi
log "  D-Bus: ${UP_RDNS}.* → ${STEALTH_RDNS}.*"

# 2d. Protocol message prefixes (frida:rpc, frida:stdout, frida:stderr)
# Cover ALL surrounding-character variants. The bare s/frida:rpc/yszint:rpc/g
# catches escaped-quote forms (`\"frida:rpc\"` in Vala source for rpc.vala
# line 73's `json.index_of ("\\\"frida:rpc\\\"")` substring check). The
# explicit quoted variants are kept for self-documenting intent.
# Safe to do bare: `frida:rpc` is a protocol-identifier-only string that
# should never appear in any context other than these literals.
for dir in subprojects/frida-core subprojects/frida-gum subprojects/frida-python; do
    [[ -d "$REPO_ROOT/$dir" ]] || continue
    sed_in "$REPO_ROOT/$dir" "*.vala *.js *.py *.c *.ts" \
        -e "s/${UP}:rpc/${ST}:rpc/g" \
        -e "s/${UP}:stdout/${ST}:stdout/g" \
        -e "s/${UP}:stderr/${ST}:stderr/g"
done
log "  Protocol prefixes: ${UP}:* → ${ST}:*"

# 2e. SELinux file contexts
sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala *.c" \
    -e "s/${UP_SELINUX}/${STEALTH_SELINUX_TYPE}/g"
log "  SELinux type: ${UP_SELINUX} → ${STEALTH_SELINUX_TYPE}"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 3: Build System
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 3: Build system"

# 3a. Root meson.build project name
sed_file "meson.build" \
    -e "s/project('${UP}'/project('${ST}'/g" \
    -e "s/'${UP}_version'/'${ST}_version'/g" \
    -e "s/${UP}_version\.py/${ST}_version.py/g" \
    -e "s/'${UP}_tools'/'${ST}_tools'/g" \
    -e "s/'${UP}_python'/'${ST}_python'/g" \
    -e "s/'${UP}_node'/'${ST}_node'/g" \
    -e "s/'${UP}_clr'/'${ST}_clr'/g" \
    -e "s/'${UP}_swift'/'${ST}_swift'/g" \
    -e "s/'${UP}_qml'/'${ST}_qml'/g"
log "  Root meson.build"

# 3b. Meson options
sed_file "meson.options" \
    -e "s/${UP}_tools/${ST}_tools/g" \
    -e "s/${UP}_python/${ST}_python/g" \
    -e "s/${UP}_node/${ST}_node/g" \
    -e "s/${UP}_clr/${ST}_clr/g" \
    -e "s/${UP}_swift/${ST}_swift/g" \
    -e "s/${UP}_qml/${ST}_qml/g" \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-inject/${ST}-inject/g"
log "  Meson options"

# 3c. G_LOG_DOMAIN in subproject meson.build files
sed_in "$REPO_ROOT/subprojects" "meson.build" \
    -e "s/G_LOG_DOMAIN=\"${UP_P}\"/G_LOG_DOMAIN=\"${ST_P}\"/g"
log "  G_LOG_DOMAIN"

# 3d. File prefix maps (debug info obfuscation)
for mapping in "${STEALTH_PREFIX_MAPS[@]}"; do
    original="${mapping%%=*}"
    replacement="${mapping##*=}"
    sed_in "$REPO_ROOT/subprojects" "meson.build" \
        -e "s|${original}=${original}|${original}=${replacement}|g"
done
log "  File prefix maps"

# 3e. Binary target names in meson.build
sed_in "$REPO_ROOT/subprojects/frida-core" "meson.build" \
    -e "s/'${UP}-server/'${ST}-server/g" \
    -e "s/'${UP}-agent/'${ST}-agent/g" \
    -e "s/'${UP}-gadget/'${ST}-gadget/g" \
    -e "s/'${UP}-helper/'${ST}-helper/g" \
    -e "s/'${UP}-inject/'${ST}-inject/g" \
    -e "s/\"${UP}-server/\"${ST}-server/g" \
    -e "s/\"${UP}-agent/\"${ST}-agent/g" \
    -e "s/\"${UP}-gadget/\"${ST}-gadget/g" \
    -e "s/\"${UP}-helper/\"${ST}-helper/g"
log "  Binary target names"

# 3f. Agent entrypoint symbol (including meson.build linker export flags)
sed_in "$REPO_ROOT/subprojects" "*.vala *.c *.h meson.build" \
    -e "s/${UP}_agent_main/${ST}_agent_main/g"
log "  Agent entrypoint symbol"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 4: Thread Names
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 4: Thread names"

sed_in "$REPO_ROOT/subprojects" "*.vala *.c" \
    -e "s/\"${UP}-server-main-loop\"/\"${ST}-server-main-loop\"/g" \
    -e "s/\"${UP}-android-helper\"/\"${ST}-android-helper\"/g" \
    -e "s/\"${UP}-main-loop\"/\"${ST}-main-loop\"/g" \
    -e "s/\"${UP}-logcat\"/\"${ST}-logcat\"/g"
log "  Thread name patterns"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 5: JavaScript Runtime (GumJS)
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 5: JavaScript runtime"

if [[ -d "$REPO_ROOT/subprojects/frida-gum/bindings/gumjs/runtime" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-gum/bindings/gumjs/runtime" "*.js" \
        -e "s/'${UP}:rpc'/'${ST}:rpc'/g" \
        -e "s/\"${UP}:rpc\"/\"${ST}:rpc\"/g"
    log "  GumJS runtime RPC protocol"
fi

# Java bridge log prefix
if [[ -d "$REPO_ROOT/subprojects/frida-java-bridge" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-java-bridge" "*.js" \
        -e "s/\[${UP}-java-bridge\]/[${ST}-java-bridge]/g"
    log "  Java bridge log prefix"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 6: Python Bindings
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 6: Python bindings"

for setup_file in \
    "subprojects/frida-python/setup.py" \
    "subprojects/frida-python/setup.cfg" \
    "subprojects/frida-python/pyproject.toml"; do
    sed_file "$setup_file" \
        -e "s/name=\"${UP}\"/name=\"${ST}\"/g" \
        -e "s/name='${UP}'/name='${ST}'/g" \
        -e "s/${UP_AUTHOR}/${STEALTH_AUTHOR}/g" \
        -e "s/${UP_EMAIL}/${STEALTH_EMAIL}/g" \
        -e "s|${UP_URL}|${STEALTH_URL}|g" \
        -e "s/\"${UP}\"/\"${ST}\"/g"
done
log "  Python setup files"

# Python C extension macros
EXT_C="$REPO_ROOT/subprojects/frida-python/frida/_frida/extension.c"
if [[ -f "$EXT_C" ]]; then
    sed -i "s/PY${UP_U}_/PY${ST_U}_/g" "$EXT_C"
    log "  Python C extension macros"
fi

# Python RPC protocol
sed_in "$REPO_ROOT/subprojects/frida-python" "*.py" \
    -e "s/\"${UP}:rpc\"/\"${ST}:rpc\"/g" \
    -e "s/'${UP}:rpc'/'${ST}:rpc'/g"
log "  Python RPC protocol"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 7: CLI Tools
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 7: CLI tools"

sed_file "subprojects/frida-tools/setup.py" \
    -e "s/name=\"${UP}-tools\"/name=\"${ST}-tools\"/g" \
    -e "s/name='${UP}-tools'/name='${ST}-tools'/g" \
    -e "s/${UP_AUTHOR}/${STEALTH_AUTHOR}/g" \
    -e "s/${UP_EMAIL}/${STEALTH_EMAIL}/g" \
    -e "s|${UP_URL}|${STEALTH_URL}|g" \
    -e "s/${UP_P} CLI/${ST_P} CLI/g" \
    -e "s/\[${UP_P}\]/[${ST_P}]/g" \
    -e "s/\"${UP} = /\"${ST} = /g" \
    -e "s/\"${UP}-/\"${ST}-/g"

# Tool description strings
if [[ -d "$REPO_ROOT/subprojects/frida-tools/frida_tools" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-tools/frida_tools" "*.py" \
        -e "s/${UP_P}'s/${ST_P}'s/g"
fi
log "  CLI tools setup + descriptions"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 8: deps.toml
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 8: deps.toml"

DEPS_TOML="$REPO_ROOT/releng/deps.toml"
if [[ -f "$DEPS_TOML" ]]; then
    sed -i \
        -e "s|embedder_string=${UP_V8}|embedder_string=${STEALTH_V8_EMBEDDER}|g" \
        -e "s|embedder_string=-${UP}|embedder_string=${STEALTH_V8_EMBEDDER}|g" \
        "$DEPS_TOML"
    log "  V8 embedder: ${UP_V8} → ${STEALTH_V8_EMBEDDER}"

    for pair in "${STEALTH_FORK_URLS[@]}"; do
        orig="${pair%%|*}"
        repl="${pair##*|}"
        sed -i "s|${orig}|${repl}|g" "$DEPS_TOML"
        log "  Fork URL: ${orig} → ${repl}"
    done
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 9: Version Scripts
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 9: Version scripts"

ROOT_VERSION_SRC="$REPO_ROOT/releng/${UP}_version.py"
ROOT_VERSION_DST="$REPO_ROOT/releng/${ST}_version.py"
if [[ -f "$ROOT_VERSION_SRC" && ! -f "$ROOT_VERSION_DST" ]]; then
    cp "$ROOT_VERSION_SRC" "$ROOT_VERSION_DST"
    sed -i "s/${UP_P}Version/${ST_P}Version/g" "$ROOT_VERSION_DST"
    echo "# Stub — see ${ST}_version.py" > "$ROOT_VERSION_SRC"
    log "  Root: ${UP}_version.py → ${ST}_version.py"
elif [[ -f "$ROOT_VERSION_DST" ]]; then
    sed -i "s/${UP_P}Version/${ST_P}Version/g" "$ROOT_VERSION_DST"
fi

for subdir in subprojects/frida-core subprojects/frida-gum subprojects/frida-python \
              subprojects/frida-tools subprojects/frida-node subprojects/frida-swift \
              subprojects/frida-qml subprojects/frida-clr; do
    sub_src="$REPO_ROOT/$subdir/releng/${UP}_version.py"
    sub_dst="$REPO_ROOT/$subdir/releng/${ST}_version.py"

    if [[ -f "$sub_src" && ! -f "$sub_dst" ]]; then
        cp "$sub_src" "$sub_dst"
        sed -i "s/${UP_P}Version/${ST_P}Version/g" "$sub_dst"
        echo "# Stub — see ${ST}_version.py" > "$sub_src"
    elif [[ -f "$sub_dst" ]]; then
        sed -i "s/${UP_P}Version/${ST_P}Version/g" "$sub_dst"
    fi

    # Update meson.build references
    sub_meson="$REPO_ROOT/$subdir/meson.build"
    [[ -f "$sub_meson" ]] && sed -i "s/${UP}_version\.py/${ST}_version.py/g" "$sub_meson"
done
log "  Subproject version scripts"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 10: macOS plist
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 10: Platform-specific"

sed_in "$REPO_ROOT/subprojects/frida-core" "*.plist" \
    -e "s/<string>${UP_P}<\/string>/<string>${ST_P}<\/string>/g" \
    -e "s/${UP_RDNS}\./${STEALTH_RDNS}./g"
log "  macOS plist files"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 11: Android Helper
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 11: Android helper"

if [[ -d "$REPO_ROOT/subprojects/frida-core/src/android-helper" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-core/src/android-helper" "*.java" \
        -e "s/package ${UP_RDNS}\./package ${STEALTH_RDNS}./g"
    log "  Android helper Java packages"
fi

# Helper DEX path references
sed_in "$REPO_ROOT/subprojects/frida-core/src" "*.vala" \
    -e "s/${UP}-helper-/${ST}-helper-/g" \
    -e "s/\"${UP}-helper/\"${ST}-helper/g"
log "  Helper DEX references"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 12: VAPI files
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 12: VAPI files"

sed_in "$REPO_ROOT/subprojects" "*.vapi" \
    -e "s/namespace ${UP_P}/namespace ${ST_P}/g" \
    -e "s/${UP_P}\.\([A-Z]\)/${ST_P}.\1/g" \
    -e "s/cprefix = \"${UP_P}/cprefix = \"${ST_P}/g" \
    -e "s/lower_case_cprefix = \"${UP}_/lower_case_cprefix = \"${ST}_/g" \
    -e "s/cheader_filename = \"${UP}-/cheader_filename = \"${ST}-/g"
log "  VAPI namespace and CCode attributes"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 13: Node.js bindings
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 13: Node.js bindings"

for node_file in \
    "subprojects/frida-node/package.json" \
    "subprojects/frida-node/src/addon.cc" \
    "subprojects/frida-node/src/device.cc" \
    "subprojects/frida-node/src/signals.cc"; do
    sed_file "$node_file" \
        -e "s/\"${UP}\"/\"${ST}\"/g" \
        -e "s/${UP_P}\([A-Z]\)/${ST_P}\1/g" \
        -e "s/${UP}_/${ST}_/g"
done
log "  Node.js binding identity"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 14: Releng scripts
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 14: Releng build scripts"

sed_in_optional "$REPO_ROOT/releng" "*.py" \
    -e "s/${UP}_version/${ST}_version/g" \
    -e "s/${UP_P}Version/${ST_P}Version/g" \
    -e "s|https://build.frida.re|https://build.${ST}.local|g" \
    -e "s|https://frida.re|${STEALTH_URL}|g"
log "  Root releng scripts"

for subdir in subprojects/frida-core subprojects/frida-gum subprojects/frida-python \
              subprojects/frida-tools subprojects/frida-node; do
    [[ -d "$REPO_ROOT/$subdir/releng" ]] || continue
    sed_in "$REPO_ROOT/$subdir/releng" "*.py" \
        -e "s/${UP}_version/${ST}_version/g" \
        -e "s/${UP_P}Version/${ST_P}Version/g"
done
log "  Subproject releng scripts"

# ═══════════════════════════════════════════════════════════════════════════════
# PASS 15: Catch-all string literals
# ═══════════════════════════════════════════════════════════════════════════════
log "Pass 15: Catch-all"

# Temp agent filename pattern
sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala" \
    -e "s/\.${UP}-agent/.${ST}-agent/g"
log "  Temp agent filename pattern"

# ── 15b. String-literal error messages containing frida-server/gadget/helper ──
sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala" \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-helper/${ST}-helper/g"
log "  Error message string literals"

# ── 15c. C #include headers referencing frida-helper-*.h ──
sed_in "$REPO_ROOT/subprojects/frida-core" "*.c *.h" \
    -e "s/\"${UP}-helper/\"${ST}-helper/g" \
    -e "s/#include \"${UP}-/#include \"${ST}-/g"
log "  C include headers"

# ── 15d. Python codegen writing namespace Frida ──
sed_in "$REPO_ROOT/subprojects/frida-core" "*.py" \
    -e "s/namespace ${UP_P}/namespace ${ST_P}/g" \
    -e "s/${UP_P}\([A-Z]\)/${ST_P}\1/g" \
    -e "s/${UP}-helper/${ST}-helper/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-server/${ST}-server/g"
log "  Python codegen/embed scripts"

# ── 15e. Java helper content (re/frida/ path + string refs) ──
if [[ -d "$REPO_ROOT/subprojects/frida-core/src/android-helper" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-core/src/android-helper" "*.java" \
        -e "s/${UP}-helper/${ST}-helper/g" \
        -e "s|/${UP}-helper|/${ST}-helper|g"
    log "  Java helper content strings"
fi

# ── 15f. Releng module JS (gadget download URLs etc.) ──
sed_in_optional "$REPO_ROOT/releng" "*.js" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s|/frida/frida/|/${ST}/${ST}/|g"
log "  Releng JS modules"

# ── 15g. Fruity injector gadget references ──
sed_in "$REPO_ROOT/subprojects/frida-core" "*.vala" \
    -e "s/${UP}-gadget/${ST}-gadget/g"
log "  Fruity injector gadget refs"

# ── 15h. Shell scripts in frida-core tools/ and tests/ ──
sed_in "$REPO_ROOT/subprojects/frida-core" "*.sh" \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-helper/${ST}-helper/g"
log "  Shell scripts (tools, tests)"

# ── 15i. Gadget / test shell scripts in frida-gum ──
sed_in "$REPO_ROOT/subprojects/frida-gum" "*.sh" \
    -e "s/${UP}-gadget/${ST}-gadget/g"
log "  Gum test shell scripts"

# ── 15j. Gadget thread name in C and meson options descriptions ──
sed_in "$REPO_ROOT/subprojects/frida-core/lib/gadget" "*.c meson.build" \
    -e "s/${UP}-gadget/${ST}-gadget/g"
sed_file "subprojects/frida-core/meson.options" \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-helper/${ST}-helper/g"
log "  Gadget glue/meson thread names and descriptions"

# ── 15k. frida-tools application.py and repl.py ──
if [[ -d "$REPO_ROOT/subprojects/frida-tools" ]]; then
    sed_in "$REPO_ROOT/subprojects/frida-tools" "*.py" \
        -e "s/${UP}-server/${ST}-server/g" \
        -e "s/${UP}-gadget/${ST}-gadget/g" \
        -e "s/${UP}\\.re/${ST}.re/g"
    log "  frida-tools Python refs"
fi

# ── 15l. Python example TS files (D-Bus paths) ──
find "$REPO_ROOT/subprojects/frida-python" -name '*.ts' -print0 2>/dev/null | \
    xargs -0 -r sed -i \
    -e "s|/${UP}/|/${ST}/|g" \
    -e "s/${UP}\\.re/${ST}.re/g"
log "  Python example TS files"

# ── 15m. Releng module package.json files ──
sed_in_optional "$REPO_ROOT/releng/modules" "*.json" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-server/${ST}-server/g"
log "  Releng module package.json"

# ── 15n. GitHub CI scripts ──
if [[ -d "$REPO_ROOT/.github/scripts" ]]; then
    sed_in "$REPO_ROOT/.github/scripts" "*.sh" \
        -e "s/${UP}-server/${ST}-server/g" \
        -e "s/${UP}-gadget/${ST}-gadget/g"
    log "  GitHub CI scripts"
fi

# ── 15o. Xcode entitlements (.xcent) and Objective-C (.m) ──
sed_in "$REPO_ROOT/subprojects" "*.xcent *.m" \
    -e "s/${UP_RDNS}\./${STEALTH_RDNS}./g" \
    -e "s/${UP}-helper/${ST}-helper/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/\"${UP}-gadget/\"${ST}-gadget/g"
log "  Xcode entitlements and Objective-C"

# ── 15p. Linker symbol export files (.def, .symbols, .version) ──
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f \( -name '*.def' -o -name '*.symbols' -o -name '*.version' \) \
    -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/${UP}_agent_main/${ST}_agent_main/g"
log "  Linker symbol export files"

# ── 15q. Test Makefiles and helper Makefiles ──
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f -name 'Makefile*' -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/${UP}_agent_main/${ST}_agent_main/g" \
    -e "s/${UP}-helper/${ST}-helper/g" \
    -e "s/${UP}-helpers/${ST}-helpers/g" \
    -e "s/${UP_RDNS}\./${STEALTH_RDNS}./g" \
    -e "s|/${UP}/|/${ST}/|g"
log "  Makefiles"

# ── 15r. CI workflow files (.yml) ──
for dir in "$REPO_ROOT" "$REPO_ROOT/subprojects/frida-core"; do
    [[ -d "$dir/.github" ]] || continue
    sed_in "$dir/.github" "*.yml" \
        -e "s/${UP}-server/${ST}-server/g" \
        -e "s/${UP}-gadget/${ST}-gadget/g" \
        -e "s/${UP}-helper/${ST}-helper/g"
done
[[ -f "$REPO_ROOT/.cirrus.yml" ]] && sed -i \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-helper/${ST}-helper/g" "$REPO_ROOT/.cirrus.yml"
log "  CI workflow files"

# ── 15s. .gitignore ──
[[ -f "$REPO_ROOT/.gitignore" ]] && sed -i \
    -e "s/${UP}-gadget/${ST}-gadget/g" \
    -e "s/${UP}-server/${ST}-server/g" "$REPO_ROOT/.gitignore"
log "  .gitignore"

# ── 15t. Fish completions ──
sed_in "$REPO_ROOT/subprojects/frida-tools" "*.fish" \
    -e "s/${UP}-server/${ST}-server/g" \
    -e "s/${UP}-gadget/${ST}-gadget/g"
log "  Shell completions"

# ====================================================================
# PASS 16: Extended coverage (added 2026-05-20)
#
# Catches 7 categories the March 17 (17.6.x → 17.8.2) rebase had to fix
# manually after the script ran. Cross-referenced against actual leaks
# observed on a fresh 17.9.10 upstream checkout. Each sub-pass targets
# one specific class of leak — see per-pass comments.
# ====================================================================
log "Pass 16: Extended coverage (rebase-derived fixes)"

# -- 16a. Vala 'Frida.lowercase_identifier' qualified calls --
# Pass 1a catches 'Frida.PascalCase' but not 'Frida.helper_path',
# 'Frida.get_main_context()', 'Frida.agent_path', 'Frida.compiler_backend_path'
# (8 leaks across host-session.vala / helper-process.vala / compiler.vala
# on fresh 17.9.10).
sed_in "$REPO_ROOT/subprojects" "*.vala" \
    -e "s/\\b${UP_P}\\.\\([a-z]\\)/${ST_P}.\\1/g"
log "  Vala 'Frida.lowercase_func()' qualified calls"

# -- 16b. FRIDA_* macros in meson.build (config.h symbol generators) --
# Pass 1c does FRIDA_ -> YSZINT_ in *.c *.h *.vala *.vapi but NOT meson.build.
# Result: cdata.set_quoted('FRIDA_VERSION', ...) survives. Once a .c file is
# renamed via pass 1c, the build fails with 'use of undeclared identifier
# YSZINT_VERSION' because config.h was generated with FRIDA_VERSION.
#
# Also catches HAVE_FRIDA_GLIB (the build define indicating yszint's glib
# fork is in use). Per user-memory '0-yszint-setup.md' Bug 3, this rename
# is required for SIGSEGV avoidance in frida-gum.
sed_in "$REPO_ROOT/subprojects" "meson.build" \
    -e "s/'${UP_U}_/'${ST_U}_/g" \
    -e "s/\"${UP_U}_/\"${ST_U}_/g" \
    -e "s/HAVE_${UP_U}_GLIB/HAVE_${ST_U}_GLIB/g" \
    -e "s/-DHAVE_${UP_U}_GLIB/-DHAVE_${ST_U}_GLIB/g"
# Also rename the define in source files that test for it
sed_in "$REPO_ROOT/subprojects" "*.c *.h *.vala" \
    -e "s/HAVE_${UP_U}_GLIB/HAVE_${ST_U}_GLIB/g"
log "  FRIDA_* macros in meson.build (config.h symbols, HAVE_FRIDA_GLIB)"

# -- 16c. #include "frida-*.h" in Objective-C (.m) files --
# Pass 15c covers .c and .h but not .m. darwin-*-glue.m, gadget-darwin.m,
# device-monitor-darwin.m all #include "frida-core.h" / "frida-base.h" /
# "frida-tvos.h" and stay broken.
sed_in "$REPO_ROOT/subprojects/frida-core" "*.m" \
    -e "s/#include \"${UP}-/#include \"${ST}-/g" \
    -e "s/#include <${UP}-/#include <${ST}-/g"
log "  ObjC #include paths"

# -- 16d. Assembly symbol names ('.S' / '.s' files) --
# Linker errors observed in March session: '_frida_set_errno',
# '_frida_on_syscall_error' in src/linux/helpers/*.S (capital-S = preprocessed).
# Also catches non-underscore-prefixed macros like `frida_asm_align`,
# `FRIDA_MAX_ERRNO` referenced from same-directory .h headers which DO
# get rewritten by Pass 1c (since .h is in Pass 1c's scope).
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f \( -name '*.S' -o -name '*.s' \) \
    -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/_${UP}_/_${ST}_/g" \
    -e "s/\\b${UP}_/${ST}_/g" \
    -e "s/${UP_U}_/${ST_U}_/g"
log "  Assembly '.S/.s' symbol names (incl. asm macros, MAX_ERRNO)"

# -- 16e. Python embed/modulate scripts (libc-shim / agent ctors) --
# api/generate.py, lib/agent/modulate.py emit C code with literal symbol
# names: frida_libc_shim_init/_deinit, frida_on_load/_unload. Pass 15d
# catches 'namespace Frida' and 'FridaX' patterns but not these snake_case
# strings inside Python string literals.
sed_in "$REPO_ROOT/subprojects/frida-core" "*.py" \
    -e "s/${UP}_libc_shim_init/${ST}_libc_shim_init/g" \
    -e "s/${UP}_libc_shim_deinit/${ST}_libc_shim_deinit/g" \
    -e "s/${UP}_on_load/${ST}_on_load/g" \
    -e "s/${UP}_on_unload/${ST}_on_unload/g" \
    -e "s/${UP}_agent_main/${ST}_agent_main/g"
log "  Python embed/modulate scripts (libc-shim, ctor names)"

# -- 16f. api/generate.py public-API codegen --
# api/generate.py writes frida-core.gir / frida-core.h / frida-core.vapi etc.
# Inside its string literals it emits 'Frida...', 'frida_...', 'FRIDA_TYPE_...'
# for public API types. Pass 1c is C-only; this targets the Python that
# GENERATES the C.
GEN_PY="$REPO_ROOT/subprojects/frida-core/src/api/generate.py"
if [[ -f "$GEN_PY" ]]; then
    # generate.py emits C source via f-strings: writing FRIDA_TYPE_X,
    # frida_unref, frida_get_X. The previously-targeted quote-prefixed
    # patterns don't catch identifiers in the middle of f-strings.
    # Solution: rewrite ALL FRIDA_ / frida_ / Frida{} occurrences in
    # this single file. (Comments inside generate.py should be stealth
    # anyway; nothing in this file should retain frida_ identifiers.)
    #
    # Also catches Python %-format and {} templates: Frida%(name)s and
    # Frida{name} — generate.py emits PascalCase type names this way.
    sed -i \
        -e "s/${UP_U}_/${ST_U}_/g" \
        -e "s/\\b${UP}_/${ST}_/g" \
        -e "s/${UP_P}\([A-Z][a-zA-Z]*\)/${ST_P}\1/g" \
        -e "s/${UP_P}%/${ST_P}%/g" \
        -e "s/${UP_P}{/${ST_P}{/g" \
        -e "s/'${UP}-/'${ST}-/g" \
        -e "s/\"${UP}-/\"${ST}-/g" \
        -e "s/f\"${UP}-/f\"${ST}-/g" \
        -e "s/f'${UP}-/f'${ST}-/g" \
        "$GEN_PY"
    log "  api/generate.py codegen string literals"
fi

# -- 16f_post. embed-helper.py / embed-agent.py output-basename + asset filenames --
# embed-helper.py / embed-agent.py construct file paths whose basenames
# become the resource-compiler symbol names. Need both:
#  - --output-basename frida-data-X       → yszint-data-X
#    (drives the .vapi/.h/.c output names)
#  - frida-agent-{arch}.so / frida-helper-{arch}
#    (drives the embedded-asset filenames → resource-compiler getter
#     names like get_frida_agent_arm64_so_blob)
for embed_py in "$REPO_ROOT/subprojects/frida-core/src/embed-helper.py" \
                "$REPO_ROOT/subprojects/frida-core/src/embed-agent.py"; do
    [[ -f "$embed_py" ]] || continue
    sed -i \
        -e "s|${UP}-data-|${ST}-data-|g" \
        -e "s|${UP}-agent|${ST}-agent|g" \
        -e "s|${UP}-helper|${ST}-helper|g" \
        "$embed_py"
done
log "  embed-helper.py / embed-agent.py basename + asset filenames"

# -- 16g. G_DECLARE_FINAL_TYPE third argument (module prefix) --
# In G_DECLARE_FINAL_TYPE (FooBar, foo_bar, MODULE_PREFIX, TYPE, Parent),
# arg 3 is the macro-emission prefix. The script catches leading-attached
# patterns like 'FRIDA_TYPE_' (in 1c) but not the standalone 'FRIDA' in
# this macro position. Example: frida-python/extension.c line 157,
# frida-core lib/pipe/pipe-glue.h.
sed_in "$REPO_ROOT/subprojects" "*.c *.h" \
    -e "s/G_DECLARE_FINAL_TYPE (\\([^,]*\\), \\([^,]*\\), ${UP_U},/G_DECLARE_FINAL_TYPE (\\1, \\2, ${ST_U},/g" \
    -e "s/G_DECLARE_DERIVABLE_TYPE (\\([^,]*\\), \\([^,]*\\), ${UP_U},/G_DECLARE_DERIVABLE_TYPE (\\1, \\2, ${ST_U},/g"
log "  G_DECLARE_FINAL_TYPE module-prefix arg"

# -- 16h. Rename frida-* source files on disk to yszint-* --
# Pass 3 / pass 15 rename meson.build *references* to 'yszint-helper-types.vala'
# but leave the actual file named 'frida-helper-types.vala' on disk -- build
# fails 'File frida-helper-types.vala does not exist'.
#
# We chose Option A: rename the source files to match the script's intent.
# Source filenames don't reach the runtime detection surface; only their
# build-system refs matter, and those were already renamed.
#
# Scope (yes-rename): src/, lib/, server/, inject/, portal/  -- runtime sources
# Scope (no-rename): devkit/, releng/, tests/, third-party    -- shipped
#                                                                examples
for sp_dir in subprojects/frida-core subprojects/frida-gum; do
    [[ -d "$REPO_ROOT/$sp_dir" ]] || continue
    for area in src lib server inject portal; do
        area_path="$REPO_ROOT/$sp_dir/$area"
        [[ -d "$area_path" ]] || continue
        find "$area_path" \( "${PRUNE_ARGS[@]}" \) -prune -o \
            -type f -name "${UP}-*" -print0 2>/dev/null | \
            while IFS= read -r -d '' f; do
                # Get just the basename component, replace prefix
                dir=$(dirname "$f")
                base=$(basename "$f")
                new_base="${ST}-${base#${UP}-}"
                new="$dir/$new_base"
                if [[ "$f" != "$new" && ! -e "$new" ]]; then
                    mv "$f" "$new" 2>/dev/null || true
                fi
            done
    done
done
log "  File rename: frida-* -> yszint-* (src/lib/server/inject/portal)"

# -- 16i. frida-glue.c (file rename + meson reference) --
# Special case: src/frida-glue.c is at the top of src/, doesn't fit under
# the inner directories pattern above. Rename it and any meson.build refs.
for sp_dir in subprojects/frida-core; do
    glue_old="$REPO_ROOT/$sp_dir/src/${UP}-glue.c"
    glue_new="$REPO_ROOT/$sp_dir/src/${ST}-glue.c"
    if [[ -f "$glue_old" && ! -e "$glue_new" ]]; then
        mv "$glue_old" "$glue_new"
    fi
    # Update meson.build refs (the existing script's pass 15c handles
    # the #include side; this handles the source-list side)
    if [[ -f "$REPO_ROOT/$sp_dir/src/meson.build" ]]; then
        sed -i "s|'${UP}-glue\\.c'|'${ST}-glue.c'|g" "$REPO_ROOT/$sp_dir/src/meson.build"
    fi
done
log "  Top-level src/frida-glue.c rename"

# ====================================================================
# PASS 17: Post-Pass-16 gap closures (added 2026-05-20 mid-rebase)
#
# Three new leak categories discovered while completing the 17.8.2 →
# 17.9.10 rebase. Each surfaced AFTER Pass 16's coverage was complete.
# See docs/REBASE_17.9.10_EXECUTION_LOG.md gap list 9-11.
# ====================================================================
log "Pass 17: Post-rebase gap closures"

# -- 17a. #include "frida-*.h" string-literal include paths in C/C++ --
# Pass 1c rewrites IDENTIFIERS in *.c *.h *.vala *.vapi, but the regex
# 'Frida\([A-Z][a-zA-Z]*\)' doesn't match lowercase 'frida-' nor does
# the 'FRIDA_' regex. String-literal #include paths like
#   #include "frida-selinux.h"
#   #include "frida-base.h"
# survive. Found in subprojects/frida-core/server/server-glue.c and
# subprojects/frida-core/inject/inject-glue.c on fresh 17.9.10.
sed_in "$REPO_ROOT/subprojects" "*.c *.h *.cpp *.cc *.hpp" \
    -e "s|\"${UP}-|\"${ST}-|g" \
    -e "s|<${UP}-|<${ST}-|g"
log "  C/C++ #include \"${UP}-*\" → \"${ST}-*\""

# -- 17b. GIR / typelib filename literals in meson.build --
# Pass 16b rewrites FRIDA_* macros and 'FRIDA_*'/"FRIDA_*" quoted forms,
# but doesn't catch CamelCase-with-version-suffix like:
#   core_gir_name = f'Frida-@api_version@.gir'
#   output: f'Frida-@api_version@.typelib'
#   base_gir_name = f'FridaBase-@api_version@.gir'
# These appear in subprojects/frida-core/{src,src/api,lib/base}/meson.build.
sed_in "$REPO_ROOT/subprojects" "meson.build" \
    -e "s|'${UP_P}-|'${ST_P}-|g" \
    -e "s|\"${UP_P}-|\"${ST_P}-|g" \
    -e "s|f'${UP_P}-|f'${ST_P}-|g" \
    -e "s|'${UP_P}Base-|'${ST_P}Base-|g" \
    -e "s|f'${UP_P}Base-|f'${ST_P}Base-|g"
log "  meson.build '${UP_P}-*.gir|.typelib' filename literals"

# -- 17c. 'from releng.frida_version import ...' Python imports --
# Pass 6 rewrites Python IDENTIFIERS but not module-import string paths.
# subprojects/frida-{core,gum}/tools/detect-version.py contain:
#   from releng.frida_version import detect
# When meson invokes them with MESON_SOURCE_ROOT set, the script tries
# to import releng.frida_version which doesn't exist (we shipped
# releng/yszint_version.py via stealth.conf STEALTH_SPECIAL_FILES).
# Result: ModuleNotFoundError → meson setup exits 1 cryptically.
for sp in subprojects/frida-core subprojects/frida-gum subprojects/frida-python subprojects/frida-tools; do
    [[ -d "$REPO_ROOT/$sp" ]] || continue
    sed_in "$REPO_ROOT/$sp" "*.py" \
        -e "s|from releng\.${UP}_version|from releng.${ST}_version|g" \
        -e "s|import releng\.${UP}_version|import releng.${ST}_version|g" \
        -e "s|releng/${UP}_version|releng/${ST}_version|g" \
        -e "s|\"${UP}_version\.py\"|\"${ST}_version.py\"|g" \
        -e "s|'${UP}_version\.py'|'${ST}_version.py'|g"
done
log "  Python 'from releng.${UP}_version import ...' imports"

# -- 17d. meson.build file-refs in lib/*/meson.build --
# Pass 16h renames source files on disk (frida-selinux.h → yszint-selinux.h)
# but doesn't update meson.build's `files('frida-X')` / `static_library`
# / `vala_header` / `vala_vapi` quoted-string references.
#
# IMPORTANT: only quoted-string forms 'frida-*' / "frida-*" / f'frida-*'.
# We deliberately do NOT touch `frida_X` Meson identifiers here — those
# would need a coordinated rename in the root meson.build (which defines
# variables like `frida_component_cflags`, `frida_version`, etc. that the
# whole project consumes). That's a separate Pass 18-candidate.
#
# Scope is limited to subprojects/frida-core/lib/*/ to avoid touching
# pkg-config dependency names like `dependency('frida-gum-1.0')` at the
# top level.
for sp in subprojects/frida-core; do
    [[ -d "$REPO_ROOT/$sp/lib" ]] || continue
    find "$REPO_ROOT/$sp/lib" -name meson.build -print0 2>/dev/null | \
        xargs -0 -r sed -i \
            -e "s|'${UP}-|'${ST}-|g" \
            -e "s|\"${UP}-|\"${ST}-|g" \
            -e "s|f'${UP}-|f'${ST}-|g" \
            -e "s|=${UP}-|=${ST}-|g"
done
log "  meson.build 'frida-*.X' file-string refs in lib/*/"

# -- 17e. C/C++/Vala source: leading-underscore _frida_* / _frida-* identifiers --
# Pass 1c uses `\bfrida_` which doesn't match `_frida_` because `_` is
# a word character (no word boundary between `_` and `f`). Result:
# generated C bindings like `_frida_sctp_connection_emit_transport_packet`
# survive into glue files (p2p-glue.c) and Vala source like
# `get_frida_helper_32_blob` survives in yszint-helper-process.vala
# (the resource-compiler-generated getters take their name from the
# input file's basename, which doesn't have the leading underscore in
# the inputs but DOES when concatenated with `get_`).
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f \( -name '*.c' -o -name '*.h' -o -name '*.cpp' -o -name '*.cc' \
               -o -name '*.hpp' -o -name '*.hh' -o -name '*.vala' -o -name '*.vapi' \) \
    -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/_${UP}_/_${ST}_/g"
log "  C/C++/Vala leading-underscore _${UP}_ identifiers"

# -- 17f. C++ source: Pass-1c-equivalent for .cpp / .cc / .hpp / .hh --
# Pass 1c's scope is *.c *.h *.vala *.vapi — not C++. gumv8core.cpp uses
# FRIDA_VERSION (defined by config.h via meson cdata), which is now
# YSZINT_VERSION. Without this pass, every .cpp file that uses
# FRIDA_VERSION or Frida{Type} fails to compile.
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.hpp' -o -name '*.hh' \) \
    -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/${UP_U}_/${ST_U}_/g" \
    -e "s/\\b${UP}_/${ST}_/g" \
    -e "s/${UP_P}\([A-Z][a-zA-Z]*\)/${ST_P}\1/g"
log "  C++ .cpp/.cc/.hpp/.hh identifier prefixes (Pass-1c equivalent)"

# -- 17g. Targeted rename of internal lib/codegen refs in src/meson.build --
# Pass 16h renames the FILES (e.g. lib/base/yszint-linux.vapi), but
# subprojects/frida-core/src/meson.build still references them by their
# OLD name in `--pkg=frida-linux`, custom_target('frida-data-X'), output:
# 'frida-data-X.vapi' etc. We CAN'T blanket-rename `frida-` in src/meson.build
# because that would also rename `--pkg=frida-gum-1.0`, `--pkg=frida-gum-linux-1.0`,
# which must remain matching the frida-gum subproject's installed pkg-config.
#
# Solution: rename only the internal-component names that Pass 16h actually
# renamed on disk in src/, lib/, etc. Enumerated explicitly to keep this
# script auditable.
LIBNAMES=(
    # src/yszint-core.{h,vapi,gir} (the main library; output as libyszint-core)
    core
    # lib/*/yszint-X.{c,h,vapi} (already renamed on disk by 16h)
    linux atomics base payload pipe netif selinux helper-backend helper-process helper
    # lib/base/yszint-{darwin,tvos,jni,perf-event,linux-bpf}.{c,h,vapi}
    darwin tvos jni perf-event linux-bpf
    # src/yszint-data-{android,helper-backend,helper-process,icons,agent,darwin,simmy,compiler,barebone}.{vapi,h,c}
    data-android data-helper-backend data-helper-process data-icons data-agent
    data-darwin data-simmy data-compiler data-barebone
)
for name in "${LIBNAMES[@]}"; do
    for sp in subprojects/frida-core; do
        [[ -d "$REPO_ROOT/$sp" ]] || continue
        find "$REPO_ROOT/$sp" -name meson.build \( "${PRUNE_ARGS[@]}" \) -prune -o \
            -name meson.build -print0 2>/dev/null | xargs -0 -r sed -i \
            -e "s|'${UP}-${name}|'${ST}-${name}|g" \
            -e "s|\"${UP}-${name}|\"${ST}-${name}|g" \
            -e "s|=${UP}-${name}|=${ST}-${name}|g" \
            -e "s|/${UP}-${name}|/${ST}-${name}|g"
    done
done
log "  Targeted rename of internal lib/codegen refs (${#LIBNAMES[@]} names)"

# -- 17g_post. frida-python / frida-tools meson.build: dependency('frida-core-1.0') --
# frida-python and frida-tools subproject root meson.builds resolve
# their dependency on frida-core via `dependency('frida-core-1.0', ...)`.
# We renamed frida-core's pkg-config to yszint-core-1.0 (via Pass 17g
# rewrites + frida-core's own meson.override_dependency call), so these
# consumer references must match.
for mb in subprojects/frida-python/meson.build subprojects/frida-tools/meson.build; do
    [[ -f "$REPO_ROOT/$mb" ]] || continue
    sed -i \
        -e "s|dependency('${UP}-core-|dependency('${ST}-core-|g" \
        -e "s|dependency(\"${UP}-core-|dependency(\"${ST}-core-|g" \
        "$REPO_ROOT/$mb"
done
log "  frida-python/frida-tools dependency('frida-core-1.0') refs"

# -- 17h_pre. lib/{agent,gadget}/meson.build: modulate.py symbol args --
# Pass 16e renames frida_libc_shim_init/_deinit/on_load/on_unload inside
# *.py files. But the meson.build INVOKES modulate.py with these as
# string-literal arguments:
#   operations = ['--move', 'constructor', 'frida_libc_shim_init', 'first']
# Result: modulate.py is given 'frida_libc_shim_init' to look up, but the
# binary contains 'yszint_libc_shim_init' → 'no constructor named ...'.
for mb in subprojects/frida-core/lib/agent/meson.build subprojects/frida-core/lib/gadget/meson.build; do
    [[ -f "$REPO_ROOT/$mb" ]] || continue
    sed -i \
        -e "s/'${UP}_libc_shim_init'/'${ST}_libc_shim_init'/g" \
        -e "s/'${UP}_libc_shim_deinit'/'${ST}_libc_shim_deinit'/g" \
        -e "s/'${UP}_on_load'/'${ST}_on_load'/g" \
        -e "s/'${UP}_on_unload'/'${ST}_on_unload'/g" \
        -e "s/'${UP}-agent-modulated'/'${ST}-agent-modulated'/g" \
        -e "s/'lib${UP}-agent-modulated'/'lib${ST}-agent-modulated'/g" \
        -e "s/'${UP}-gadget-modulated'/'${ST}-gadget-modulated'/g" \
        -e "s/'lib${UP}-gadget-modulated'/'lib${ST}-gadget-modulated'/g" \
        "$REPO_ROOT/$mb"
done
log "  lib/{agent,gadget}/meson.build modulate.py args + output names"

# -- 17h. Resource-compiler .resources namespace = Frida.Data.X --
# The resource compiler reads `namespace = Frida.Data.X` from .resources
# files to generate Vala code like `namespace Frida.Data.X { ... }`. The
# .vala files referencing this expect `Yszint.Data.X` (because Pass 1a
# already rewrote the calling .vala code). Rewrite the .resources files
# so the resource compiler emits the matching namespace.
find "$REPO_ROOT/subprojects" \( "${PRUNE_ARGS[@]}" \) -prune -o \
    -type f -name '*.resources' \
    -print0 2>/dev/null | xargs -0 -r sed -i \
    -e "s/namespace = ${UP_P}\.Data/namespace = ${ST_P}.Data/g" \
    -e "s/namespace = ${UP_P}\\b/namespace = ${ST_P}/g"
log "  .resources 'namespace = ${UP_P}.Data.*' attributes"

# ═══════════════════════════════════════════════════════════════════════════════
# DONE
# ═══════════════════════════════════════════════════════════════════════════════
log ""
log "══════════════════════════════════════════════════════════"
log "  Stealth transform complete."
log "  Config: $CONF_FILE"
log "  Namespace: ${UP_P} → ${ST_P}"
log "  Port: ${UP_PORT} → ${STEALTH_PORT}"
log "  Protocol: ${UP}:* → ${ST}:*"
log "  D-Bus: ${UP_RDNS}.* → ${STEALTH_RDNS}.*"
log "══════════════════════════════════════════════════════════"
log ""
log "Next steps:"
log "  1. Run stealth-reviewer to verify no leaks"
log "  2. Apply Android 16 patches (dlopen temp-file, zymbiote disable)"
log "  3. Build: ./configure --host=android-arm64 && make"
