# Patch C — Shadow table API via KernelPatch supercall

## What it does

Adds a JS-callable shadow API in frida-gum:

```js
Interceptor.registerShadow(addr, originalBytes);   // tell KPM the original
Interceptor.removeShadow(addr);
Interceptor.enableShadow(superkey);                // prime KPM superkey + arm mem_read hook (throws on failure)
const live = Interceptor.shadowEnabled();
```

These call into a new in-gum module (`gum/gumyszintshadow.c`) which issues
direct KernelPatch supercalls to the yszint-kpm running in the kernel,
which in turn populates the in-kernel shadow table (`src/shadow.c` in
yszint-kpm). When an anti-cheat then reads `/proc/self/mem` or calls
`process_vm_readv` against a shadowed address, the KPM serves the
original (pre-hook) bytes instead of the trampoline.

**This is the single highest-leverage feature in the whole yszint stack.**
Without it, every `Interceptor.attach()` call is detectable by trivial
self-memory scans. Anti-cheats like LIAPP, pairipcore, NeSec, and
GameGuard all do this scan. Patch C makes the trampolines invisible.

## Files touched

| File | LOC | Why |
|------|-----|-----|
| `gum/gumyszintshadow.c` | +410 | The supercall-issuing layer |
| `gum/gumyszintshadow.h` | +30 | Public API |
| `gum/meson.build` | +2 | Link the new files |
| `bindings/gumjs/gumv8interceptor.cpp` | +45 | Expose to JS (V8 / QJS) |
| 2 other binding files | small | Same JS exposure, other runtimes |

## Invariants

- **Requires yszint-kpm v1.0+ loaded** with shadow table support, and the
  KPM superkey. `enableShadow(superkey)` takes the superkey string and
  calls `gum_yszint_shadow_init()`. Without the KPM (or on a bad key) it
  **throws** (`"failed to enable shadow: KPM not reachable"`); on success it
  returns void (undefined). Agent code must wrap it in try/catch — there is
  no boolean return to check.
- **KP supercall number is hardcoded** (see `gum_yszint_shadow.c:42`).
  If the yszint-kpm changes its supercall number, this patch must
  follow. We've never changed it.
- **Standalone**: this patch does NOT depend on Patches A, B, or D. It
  applies cleanly to a stealth-only frida-gum tree.
- **Architecturally independent**: works for x86_64 and arm64; the
  supercall ABI is wrapped in a single inline asm block per arch.

## Verifying after re-apply

```bash
# Source-level
ls subprojects/frida-gum/gum/gumyszintshadow.[ch]    # files exist

# Binary-level
strings build-android-arm64/.../yszint-server | grep -c 'registerShadow'
# >= 3 (the symbol appears in JS-binding strings, dlsym table, etc.)
strings build-android-arm64/.../yszint-server | grep -c 'gum_yszint_shadow'
# >= 1

# Behavioural
tests/on_device/test_shadow_api_surface.py          # PASS (JS sees the API)
tests/on_device/test_shadow_register_roundtrip.py   # PASS (KPM table grows)
tests/on_device/test_shadow_stealth_payoff.py       # PASS (memory read returns original)
```

The `_stealth_payoff` test is the definitive proof: it installs an
Interceptor.attach, registers the original bytes via Patch C's API, then
reads `/proc/self/mem` at the hooked address and checks that the
returned bytes are the original (not the trampoline).

## Loss/regression scenario

If C is missing:
- `test_shadow_api_surface` fails: `Interceptor.enableShadow === 'undefined'`
- `test_shadow_register_roundtrip` fails: `TypeError: not a function`
- `test_shadow_stealth_payoff` fails: same TypeError

This is *exactly* what happened during today's Bug #8 bisect: I cleaned
the frida-gum tree to bisect Patch C, then forgot to re-add it. Caught
by the 3 shadow tests failing immediately after redeploy.

## Generation

```
git -C subprojects/frida-gum format-patch -1 6208a29d --stdout \
    > releng/patches/C-shadow-table-api.patch
```

Source commit: `6208a29d feat: shadow table API via direct KernelPatch supercall`.

Originally authored as commit `3c8380e4` on 2026-03-17; the current
`6208a29d` is the post-stealth-re-apply version.

## Drop this patch when

- We replace KP with a different kernel mechanism (e.g. our own LKM),
  OR
- Anti-cheats stop scanning `/proc/self/mem` (unlikely in this decade),
  OR
- Frida upstream adopts a similar shadow primitive (would require KP
  cooperation — also unlikely).

For the foreseeable future: **always keep applied.**
