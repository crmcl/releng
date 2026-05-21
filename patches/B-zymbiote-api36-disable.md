# Patch B — Skip zymbiote preload on API 36+

## What it does

Adds an early-exit in `Yszint.LinuxHostSession.preload()` that checks
`getprop ro.build.version.sdk >= 36` and skips zymbiote initialization
on Android 16+. zymbiote's ArtMethod heap-scanning corrupts the zygote
on Android 16 (ART changed); skipping it means `device.spawn()` is
disabled, but `device.attach()` continues to work.

## ⚠️ CRITICAL — sole-defender status

**This patch is currently the SOLE barrier preventing zygote brick on
Android 16.** ZygiskYszint (the intended replacement / early-injection
backstop) is OUT OF SERVICE (per workspace owner 2026-05-18). If this
patch is missing, calling `device.spawn()` on any Android 16 device
will:

1. Corrupt the zygote's ArtMethod dispatch tables
2. Cause every subsequent app fork to SIGILL inside `app_process64`
3. Render the device unusable until reboot

See `docs/KNOWN_ISSUES.md` #1 for the full failure mode.

**Therefore:** the patch MUST fall closed. If `getprop` returns an empty
string, fails, or is denied by SELinux, the gate MUST assume API ≥ 36
and skip zymbiote. The patch's `parse_int` defaults to a large number on
parse failure for exactly this reason. This is verified by
`tests/on_device/test_zymbiote_gating.py` phase 2.

## Files touched

| File | Lines | Why |
|------|-------|-----|
| `src/linux/linux-host-session.vala` | +31 | Add `try_get_android_api_level()` + gate `preload()` zymbiote init |

## Invariants

1. **Fail closed.** Any failure to read API level → skip zymbiote.
2. **Log the gate decision** to stderr so test_zymbiote_gating phase 2
   can verify the gate fired:
   `yszint: Skipping zymbiote on Android 36 - spawn disabled`
3. **DO NOT** remove the gate or change the log message without
   updating `test_zymbiote_gating.GATE_MESSAGES` first.

## Verifying after re-apply

```bash
# Source-level
grep 'Skipping zymbiote' subprojects/frida-core/src/linux/linux-host-session.vala
# → should print the gate's printf line

# Binary-level
strings build-android-arm64/subprojects/frida-core/server/yszint-server \
    | grep 'Skipping zymbiote'
# → "yszint: Skipping zymbiote on Android 36 - spawn disabled"

# Behavioural — CRITICAL
tests/on_device/test_zymbiote_gating.py    # PASS (with fresh server log!)
```

**Test sanity check:** `test_zymbiote_gating` reads the server's startup
log from `/data/local/tmp/yszint-*.log`. If the file is stale (from a
previous server run that DID have Patch B), the test will give a false
PASS even when the new binary lacks Patch B. To verify the patch is
*actually in the running binary*, also check `strings` of
`/data/local/tmp/yszint-server` for the gate message.

This false-PASS scenario is how Patch B got accidentally dropped during
the Bug #8 bisect on 2026-05-20 without anyone noticing for ~6 hours.

## Generation

```
git -C subprojects/frida-core format-patch -1 667eb01b --stdout \
    > releng/patches/B-zymbiote-api36-disable.patch
```

Source commit: `667eb01b android-16: skip zymbiote preload on API 36+ [SENTINEL]`.

## Drop this patch when

(a) Upstream gates zymbiote behind API-level themselves, OR
(b) Upstream replaces zymbiote with a JNI-bridge-after-fork mechanism
    that works on API 36 ART, OR
(c) We rewrite zymbiote to patch ArtMethod entry slots directly
    (LIAPP-style — viable but maintenance-heavy), OR
(d) ZygiskYszint is repaired AND proven to install agents on every
    Android-16 fork without zygote damage.

Until then: **DO NOT REMOVE.**
