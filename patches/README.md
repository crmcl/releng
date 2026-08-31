# yszint 17.17 patch stack

`apply-stealth.sh` transforms stock Frida source into the yszint namespace. Six mbox
patches then add five yszint-specific functional changes (A through E):

| Unit | Repository | Purpose | Documentation |
|---|---|---|---|
| A | frida-core | Android 16 temp-file agent loader | `A-loader-temp-files.md` |
| B | frida-core | Disable unsafe zymbiote preload on API 36+ | `B-zymbiote-api36-disable.md` |
| C | frida-gum | KernelPatch shadow table and GumJS API | `C-shadow-table-api.md` |
| D | frida-core | Host-side temp-file cleanup; depends on A | `D-host-side-unlink.md` |
| E-gum | frida-gum | Export native `gum_yszint_kpm_ctl0` | `E-ctl0-service.md` |
| E-core | frida-core | Persistent `open_service("yszint-ctl0")`; depends on E-gum | `E-ctl0-service.md` |

## Rebase order

```bash
# Start from matching upstream submodule pins, then:
bash releng/apply-stealth.sh
# Commit the stealth transform in each modified submodule.
bash releng/apply-yszint-patches.sh
```

The runner enforces:

```text
frida-core: A -> B -> D
frida-gum:  C -> E-gum
frida-core: E-core
```

It applies with `git am --3way`; resolve and continue any upstream conflict before the next
patch. Patches target the post-stealth `yszint-*` paths, so stealth must run first.

## Rebuild native helper artifacts after Patch A changes

Patch A changes the freestanding loader ABI. Rebuild its checked-in arm64 artifacts before
building the server. From the repository root:

```bash
mkdir -p build/android-arm64
ln -sf ../frida-android-arm64.txt build/android-arm64/frida-android-arm64.txt
make -C subprojects/frida-core/src/linux/helpers build-native \
    FRIDA_HOST=android-arm64 \
    BUILDDIR="$PWD/build" \
    MESON="$PWD/releng/meson/meson.py"
./deps/toolchain-linux-x86_64/bin/ninja -C build
```

The nested crossfile symlink is required because `configure` emits
`build/frida-android-arm64.txt`, while the helper Makefile expects
`build/android-arm64/frida-android-arm64.txt`.

## Build

```bash
export ANDROID_NDK_ROOT=/opt/android-ndk-r29
./configure --host=android-arm64 -- \
    -Dfrida-core:assets=embedded \
    -Dfrida-core:helper_legacy= \
    -Dfrida-core:helper_emulated_modern= \
    -Dfrida-core:helper_emulated_legacy= \
    -Dfrida-core:compat=native
./deps/toolchain-linux-x86_64/bin/ninja -C build
```

## Validate

There is no `run_all.sh`. The directory contains 10 routine tests and one opt-in
high-rate stress test. Run the routine set with:

```bash
for t in tests/on_device/test_*.py; do
    case "$t" in *test_ctl0_service_high_rate.py) continue;; esac
    echo "=== $t ==="
    python3 "$t" || exit 1
done
```

`test_ctl0_service_high_rate.py` is currently a known failing stress contract: its
10,000-tap run can close/wedge the transport. Do not include it in routine validation;
see `tests/on_device/README.md`.

Coverage:

- A/D: `test_dlopen_temp_file.py`
- B: `test_zymbiote_gating.py`
- C: `test_shadow_api_surface.py`, `test_shadow_register_roundtrip.py`,
  `test_shadow_pvr_payoff.py`, `test_shadow_stealth_payoff.py`
- E: five `test_ctl0_service_*.py` tests

Prerequisites and safety constraints are in `tests/on_device/README.md`.

## Re-author a patch

After resolving an upstream change, commit the final submodule result and regenerate its
mbox from that commit:

```bash
git format-patch -1 HEAD --stdout > ../../releng/patches/<patch-name>.patch
```

Update the corresponding `.md` and this index in the same change. Current fork branches are
published under `crmcl/frida-{core,gum,python,tools}`, `crmcl/releng`, and
`crmcl/frida-bindgen`.
