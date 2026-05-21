# yszint patches/

Four standalone patches that turn a stealth-renamed (post-`apply-stealth.sh`)
yszint tree into a working Android-16-ready build.

These exist as patches (rather than living as commits on `yszint-17.x`
branches) because:

1. **Rebases never lose them.** During the 2026-05-20 Bug #8 bisect we
   accidentally dropped Patch C and Patch B by checking out earlier
   commits; nobody noticed for 6 hours because `test_zymbiote_gating`
   was reading a stale log file. Patch files in tree make this kind of
   loss impossible: `apply-yszint-patches.sh` either applies or fails
   loudly.
2. **Each patch is independently reviewable** with its own `.md`
   describing invariants, what to grep for in the build artifacts,
   and when it can be dropped upstream.
3. **The application order is explicit** and enforced by the runner
   script.

## Run order in a fresh rebase

```bash
# 1. Check out the upstream version
cd subprojects/frida-core && git checkout 17.10.x
cd subprojects/frida-gum  && git checkout 17.10.x

# 2. Apply stealth (renames frida→yszint everywhere, fixes protocol prefixes)
bash releng/apply-stealth.sh
# (commit the result per submodule before the next step)

# 3. Apply the 4 functional patches
bash releng/apply-yszint-patches.sh

# 4. Build
./configure --host=android-arm64 -- \
    -Dfrida-core:assets=embedded \
    -Dfrida-core:helper_legacy= \
    -Dfrida-core:helper_emulated_modern= \
    -Dfrida-core:helper_emulated_legacy= \
    -Dfrida-core:compat=native
ninja -C build
```

After Patch A, the loader artifacts need rebuilding too:
```bash
cd subprojects/frida-core/src/linux/helpers
FRIDA_HOST=android-arm64 BUILDDIR=$PWD/../../../../build \
    MESON=$PWD/../../../../../releng/meson/meson.py make
```
Then re-run ninja to pick up the rebuilt loader.bin.

## Patches

| Patch | Sub | Lines | Sentinel? | Standalone? | See |
|-------|-----|-------|-----------|-------------|-----|
| A | frida-core | ~300 | yes | no (foundation) | `A-loader-temp-files.md` |
| B | frida-core |   31 | yes | yes | `B-zymbiote-api36-disable.md` |
| C | frida-gum  |  485 | yes | yes | `C-shadow-table-api.md` |
| D | frida-core |   18 | no (Bug #1 fix) | depends on A | `D-host-side-unlink.md` |

"Sentinel?" — patches marked `[SENTINEL]` in their commit message
contain the line "─── Status: NOT UPSTREAMED ──" indicating they live
on the yszint fork forever (or until a deeper restructuring obsoletes
them).

## Dependency graph

```
        ┌───┐
        │ A │ ← Patch A: temp_file_path field in BootstrapResult
        └─┬─┘
          │
        ┌─▼─┐
        │ D │ ← Patch D: host-side unlink of temp file (uses A's field)
        └───┘

        ┌───┐
        │ B │ ← Patch B: zymbiote gate (standalone)
        └───┘

        ┌───┐
        │ C │ ← Patch C: shadow API in frida-gum (standalone)
        └───┘
```

So: A must come before D, and `apply-yszint-patches.sh` enforces this.
B and C are independent.

## Verifying after rebase

After build + deploy, all four patches should pass their respective
verification — see each `.md` for the exact `grep` / `strings` /
test-on-device commands:

```bash
# Quick all-in-one
bash tests/on_device/run_all.sh    # 5/5 PASS expected
```

The 5/5 baseline tests collectively cover all four patches:

| Test | Patch verified |
|------|----------------|
| `test_dlopen_temp_file` | A (dlopen path) + D (no leak after) |
| `test_shadow_api_surface` | C (JS API exposed) |
| `test_shadow_register_roundtrip` | C (KPM table populated) |
| `test_shadow_stealth_payoff` | C (mem read returns original) |
| `test_zymbiote_gating` | B (gate fires on API 36) |

## Regenerating from new commits

If you ever need to re-author one of these patches (e.g., the upstream
context shifted enough that the patch no longer applies):

```bash
# 1. Apply the existing patch with --reject to leave .rej files
cd subprojects/frida-core
git am --reject ../../releng/patches/A-loader-temp-files.patch

# 2. Fix the .rej files manually

# 3. Commit the result with the same Subject

# 4. Regenerate the patch:
git format-patch -1 HEAD --stdout > ../../releng/patches/A-loader-temp-files.patch
```

Then update the source-commit reference at the bottom of the `.md`
so the next person can see when the patch was last hand-touched.
