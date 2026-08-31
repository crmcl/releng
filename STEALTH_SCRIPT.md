# `apply-stealth.sh` — yszint transform

This script reproducibly transforms a matching upstream Frida checkout into the yszint
namespace. Current baseline: **Frida 17.17.0**. Run it before the A-E functional patches,
because those patches target post-transform `yszint-*` paths.

## Usage

```bash
bash /path/to/yszint/releng/apply-stealth.sh \
    /path/to/yszint/releng/stealth.conf \
    /path/to/fresh-frida-checkout
# Commit each transformed submodule, then:
bash /path/to/yszint/releng/apply-yszint-patches.sh
```

The script is intended to be idempotent and partial-tree safe. It covers passes 1-17,
including namespace/protocol/build/string/file renames and post-rebase gap closures.

## Major coverage

- Vala/C/C++ namespaces and identifiers: `Frida`/`frida_*`/`FRIDA_*` → yszint
- Port 27042 → 5233; D-Bus `re.frida` → `re.yszint`; RPC/stdout/stderr protocol prefixes
- Runtime binary names, thread labels, source basenames, embedded asset symbols
- Meson options, VAPI/CCode attributes, resource namespaces, generated source references
- Python packaging and RPC protocol
- Frida 17.16+ bindgen templates:
  - `PYFRIDA_*` → `PYYSZINT_*`
  - generated calls/includes match `yszint-core.h` and `yszint_*`
  - error-domain and GObject module-prefix macros use `YSZINT`
  - C type-prefix stripping uses `Yszint` with a length-safe `sizeof` expression
  - tests use `Yszint-1.0.gir`
- Assembly and leading-underscore internal symbols where required by the yszint runtime

## Intentionally preserved names

These are ABI, package, dependency, or source-layout contracts—not stealth leaks:

- Subproject directories: `subprojects/frida-core`, `frida-gum`, `frida-python`, etc.
- Public dependency/library names such as `frida-gum-1.0` and `libfrida-gum-1.0`
- Upstream dependency repositories and `.wrap` names
- Python import/module surface: `import frida`, `_frida`, `PyInit__frida`
- Bindgen CLI/model APIs: `--frida-gir`, `frida_gir`, `is_frida_list`,
  `is_frida_options`, and external package `frida_bindgen_core`
- Source file `src/frida.vala` and the `_frida_*` symbol-map compatibility pattern
- Tests and examples where upstream-compatible spelling is part of the test/API contract

Do not broadly replace all lowercase `frida` strings: that breaks these contracts.

## Functional patches after stealth

The transform does not implement yszint's Android/KPM behavior. Apply the active patch
stack documented in `patches/README.md`:

```text
core: A -> B -> D
 gum: C -> E-gum
core: E-core
```

## Build constraints

- Android NDK r29: `ANDROID_NDK_ROOT=/opt/android-ndk-r29`
- Use the bundled Frida Vala toolchain; a stock system `valac` may not satisfy ABI checks
- Patch A changes the native loader ABI; regenerate arm64 helper artifacts before rebuilding
- Modified submodule histories must be pushed and `.gitmodules` must point at reachable
  forks before recording top-level gitlinks

## Verification

After transform + patches:

1. Inspect transformed source for unexpected runtime-visible `frida` names while respecting
   the intentional allowlist above.
2. Configure and build Android arm64.
3. Deploy the server and run the 10 routine on-device tests; keep the known-failing
   high-rate ctl0 stress test separate.
4. Verify a third-party app attach, ctl0 status/watchdog, and shadow register/remove.

The current verified build/rebase record is `../REBASE_RECOVERY.md`.

## Future improvements

- Add a deterministic transform self-test against pinned upstream 17.17 source
- Add `--dry-run` and `--verify` modes
- Make expected rename counts explicit so moved/new upstream code cannot silently escape a
  hardcoded pass
