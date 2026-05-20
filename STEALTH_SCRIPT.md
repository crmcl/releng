# apply-stealth.sh — Stealth Transform Script

Reproducible script that transforms a fresh upstream Frida checkout into
the configured stealth namespace (yszint by default).

## Usage

```bash
# 1. Clone upstream Frida fresh
git clone --recurse-submodules https://github.com/frida/frida.git /path/to/fresh
cd /path/to/fresh

# 2. Run the stealth script
bash /path/to/yszint/releng/apply-stealth.sh \
     /path/to/yszint/releng/stealth.conf \
     /path/to/fresh

# 3. Apply yszint-specific hand-written patches (Android 16, etc.)
# 4. Build
```

The script is **idempotent** — running it multiple times produces the
exact same tree hash (verified 2026-05-20 via 3-run MD5 comparison).

## What the script does

16 passes, ~7-8 seconds end-to-end on a fresh checkout:

| Pass | Coverage |
|---|---|
| 1 | Vala/C namespace renames (`namespace Frida`, `Frida.PascalCase`, `frida_*`, `FridaTypeName`, GIR namespace) |
| 2 | Protocol & network: port 27042→5233, D-Bus `re.frida.*`, protocol msg prefixes, SELinux file context |
| 3 | Build system: meson project name, options, G_LOG_DOMAIN, binary target names, agent entrypoint |
| 4 | Thread name strings (`frida-server-main-loop` etc.) |
| 5 | JavaScript runtime: GumJS RPC protocol, java-bridge log prefix |
| 6 | Python bindings: setup.py, pyproject.toml, C extension macros, RPC protocol |
| 7 | CLI tools: frida-tools setup, descriptions |
| 8 | deps.toml: V8 embedder string, fork URLs |
| 9 | Version scripts: `frida_version.py` → `yszint_version.py` (with stub) |
| 10 | macOS plist files |
| 11 | Android helper Java packages, helper DEX path references |
| 12 | VAPI files: namespace, CCode attributes |
| 13 | Node.js bindings: package.json, addon.cc etc. |
| 14 | Releng build scripts |
| 15 | Catch-all string literals (a–t: error messages, includes, codegen, etc.) |
| **16** | **Extended coverage (added 2026-05-20)** — see below |

## Pass 16: Extended coverage (the gap-closer)

Added 2026-05-20 after the original 17.6.x → 17.8.2 rebase identified 7
categories of manual cleanup that the script previously missed. Each
sub-pass targets one specific class of leak observed on a real upstream
checkout. Cross-referenced against a fresh 17.9.10 checkout — all 8 leak
categories drop to 0 after pass 16.

| Pass | Catches | Example |
|---|---|---|
| 16a | `Frida.lowercase_func()` qualified calls in Vala | `Frida.helper_path`, `Frida.get_main_context()`, `Frida.agent_path` |
| 16b | `FRIDA_*` macros in meson.build + `HAVE_FRIDA_GLIB` define | `cdata.set_quoted('FRIDA_VERSION', ...)`, `-DHAVE_FRIDA_GLIB=1` |
| 16c | `#include "frida-*.h"` in Objective-C `.m` files | `#include "frida-base.h"` in darwin-*-glue.m |
| 16d | Assembly symbol names in `.S` / `.s` files | `_frida_set_errno`, `_frida_on_syscall_error` |
| 16e | Python embed/modulate ctor name strings | `frida_libc_shim_init`, `frida_on_load`, `frida_on_unload` |
| 16f | `api/generate.py` codegen string literals | `'Frida'`, `'frida_'`, `'FRIDA_TYPE_'` inside Python `''`/`""` |
| 16g | `G_DECLARE_FINAL_TYPE` 3rd-arg module prefix | `G_DECLARE_FINAL_TYPE (Foo, foo, FRIDA, ...)` |
| 16h | **Rename `frida-*` source files on disk** in `src/`, `lib/`, `server/`, `inject/`, `portal/` | `frida-helper-types.vala` → `yszint-helper-types.vala` |
| 16i | Special case: `src/frida-glue.c` rename + meson ref | top-of-`src/` glue file |

## What the script intentionally does NOT rename

These stay `frida-*` because they are NOT runtime-detectable, OR are
shipped to library users who expect upstream-compatible names:

| Category | Examples | Why kept |
|---|---|---|
| Subproject directory names | `subprojects/frida-core/`, `subprojects/frida-gum/` | Meson subproject infrastructure |
| Library output filenames | `libfrida-core-1.0.a`, `libfrida-gum-1.0.so` | Public ABI name |
| pkg-config dependency names | `frida-gum-1.0`, `frida-gumjs-1.0` | Inter-component pkg-config refs |
| `.wrap` files | `subprojects/frida-gum.wrap` | Meson subproject directory ref |
| Devkit example files | `frida-core-example.c`, `frida-gum-example-unix.c` | Shipped to library users |
| Public API headers | `frida-core.h`, `frida-gum.h`, `frida-gumjs.h` | C API contract for embedders |
| GIR/VAPI public names | `frida-core.gir`, `frida-core.vapi` | Bindings shipped to language runtimes |
| Resource compiler binary | `frida-resource-compiler` | Internal build helper, not runtime artifact |
| Test files | `tests/frida-tests.plist`, JS-in-C test strings | Tests aren't deployed |
| Python import name | `import frida` (the package itself uses yszint internally) | API name for Python consumers |

If you need to verify what was/wasn't renamed, the script's output is
deterministic — run it and check `find . -name "frida-*"` to enumerate
the intentional kept-names.

## Validation: 8 leak categories (post-pass-16)

After running on fresh 17.9.10:

```
namespace Frida (Vala):       0 leaks
Frida.lowercase (Vala):       0 leaks   (was 10+ before 16a)
FRIDA_VERSION (meson.build):  0 leaks   (was 10+ before 16b)
HAVE_FRIDA_GLIB:              0 leaks   (was 5  before 16b)
frida-*.so in src/:           0 leaks   (was ~50 before 16h)
Assembly _frida_*:            0 leaks   (covered by 16d)
api/generate.py 'Frida':      0 leaks   (covered by 16f)
G_DECLARE_FINAL_TYPE FRIDA:   0 leaks   (was 2  before 16g)
```

Idempotency verified: 3 consecutive runs produce identical tree hash
`f19ed881d2eef0aa58f174299bfa7c1e` (MD5 of all tracked file contents,
LC_ALL=C sorted).

## Manual fixups still required after the script

Even with pass 16, the following items need hand-attention per rebase
(documented per March 17 session experience):

1. **Vala compiler version check.** `subprojects/frida-core/meson.build`
   has `valac.version().endswith('-frida')` — only Frida's custom Vala
   compiler satisfies this. yszint's prebuilt SDK includes it; system
   `valac` does not. Patch the check if building without the prebuilt
   toolchain.

2. **NDK r29 path.** `ANDROID_NDK_ROOT=/opt/android-ndk-r29 ./configure
   --host=android-arm64`. Older NDK versions may not work; user-memory
   rule "Bug 4: 4K page alignment" requires `-Wl,-z,max-page-size=4096`
   which is already in `releng/env_android.py` (the load-bearing fix).

3. **Hand-written yszint patches** (Patch A: dlopen temp-file, Patch B:
   zymbiote API-36 gate, Patch C: frida-gum shadow API). See:
   `~/yszint-kpm/docs/REBASE_PLAN_17.9.10.md` for details.

4. **Test corpus run.** After the rebuilt yszint-server is deployed,
   run all 5 tests in `tests/on_device/`. Expected: 5/5 PASS.

5. **Submodule pins.** Top-level repo's submodule pointers must be
   updated to the new commit SHAs after the script + hand-written
   patches are committed.

## Future improvements (out of scope, tracked in REBASE_METHODOLOGY_COMPARISON.md)

- Add `tests/test_apply_stealth.sh` self-test that runs the script on
  a fresh checkout and verifies leak counts are 0 for each category.
- Add a `--dry-run` mode that prints what would change without
  modifying the tree.
- Add a `--verify` mode that runs all leak-detection greps and reports
  any non-zero counts (useful in CI).
