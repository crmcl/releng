#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# apply-yszint-patches.sh — apply the yszint-specific patches A/B/C/D
# on top of an already-stealth-rewritten yszint tree.
#
# Run order in a fresh rebase:
#   1. Check out the upstream version you want to base on (e.g. 17.10.x).
#   2. bash releng/apply-stealth.sh         # frida-* → yszint-* + protocol
#   3. (commit the stealth changes per submodule)
#   4. bash releng/apply-yszint-patches.sh  # ← THIS SCRIPT
#   5. ./configure --host=android-arm64 ... && ninja -C build
#
# Each patch file in releng/patches/ has a sibling .md describing its
# invariants, why it exists, and when it can be dropped upstream.
#
# REQUIRED ORDER:
#   A  →  B  →  D     (frida-core; D depends on A's temp_file_path field)
#   C                  (frida-gum; standalone)
#
# Patches use `git am --keep-non-patch` to preserve their original
# commit messages and authorship. If a patch fails to apply, the
# script aborts and leaves the submodule in `git am` state so you
# can inspect the conflict, fix manually, and `git am --continue`.

set -euo pipefail

# Resolve repo root (the directory containing this script's parent)
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHDIR="$REPO_ROOT/releng/patches"

# Fail loudly if releng/patches/ is missing
if [[ ! -d "$PATCHDIR" ]]; then
    echo "FATAL: $PATCHDIR not found" >&2
    exit 1
fi

# Helper: apply one patch into one submodule. Aborts the script on failure.
apply_patch() {
    local subproject="$1" patch_basename="$2"
    local patch_file="$PATCHDIR/$patch_basename"
    local sub_dir="$REPO_ROOT/subprojects/$subproject"

    if [[ ! -f "$patch_file" ]]; then
        echo "FATAL: patch file missing: $patch_file" >&2
        exit 1
    fi
    if [[ ! -d "$sub_dir" ]]; then
        echo "FATAL: submodule missing: $sub_dir" >&2
        exit 1
    fi

    printf "==> %-15s ← %s\n" "$subproject" "$patch_basename"
    pushd "$sub_dir" >/dev/null

    # Sanity check: refuse to apply if there are uncommitted changes
    # (the patch's commit message would otherwise mix with whatever
    # the user had staged, hiding the patch contents).
    if ! git diff-index --quiet HEAD --; then
        echo "FATAL: $sub_dir has uncommitted changes; commit or stash first" >&2
        popd >/dev/null
        exit 1
    fi

    # Refuse to apply on top of a non-stealth tree — protect against
    # running this on raw upstream (where the patches won't apply because
    # the file paths have frida-* names, not yszint-*).
    if ! git log --oneline -1 2>/dev/null | grep -q 'stealth:\|frida→yszint\|yszint:'; then
        echo "WARN: $subproject HEAD doesn't look stealth-applied; the patches may fail" >&2
    fi

    git am --keep-non-patch "$patch_file"

    popd >/dev/null
}

echo "yszint patch application — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "REPO_ROOT=$REPO_ROOT"
echo

# ── frida-core: A first (Patch D depends on A's temp_file_path field) ──
apply_patch frida-core A-loader-temp-files.patch
apply_patch frida-core B-zymbiote-api36-disable.patch
apply_patch frida-core D-host-side-unlink.patch

# ── frida-gum: C standalone ──
apply_patch frida-gum  C-shadow-table-api.patch

echo
echo "✓ All 4 patches applied. Next:"
echo "    1. After Patch A: rebuild src/linux/helpers/artifacts/native/arm64/"
echo "       (upstream's prebuilt loader.bin doesn't know temp_file_path):"
echo "         cd subprojects/frida-core/src/linux/helpers"
echo "         FRIDA_HOST=android-arm64 BUILDDIR=\$PWD/../../../../build \\"
echo "             MESON=\$PWD/../../../../../releng/meson/meson.py make"
echo "    2. Configure + build:"
echo "         ./configure --host=android-arm64 -- \\"
echo "             -Dfrida-core:assets=embedded \\"
echo "             -Dfrida-core:helper_legacy= \\"
echo "             -Dfrida-core:helper_emulated_modern= \\"
echo "             -Dfrida-core:helper_emulated_legacy= \\"
echo "             -Dfrida-core:compat=native"
echo "         ninja -C build"
echo "    3. Smoke-test: deploy + run tests/on_device/test_*.py"
echo "    4. Commit submodule pins on top-level."
