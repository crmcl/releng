# Patch A — Load agent .so from /data/local/tmp temp file

## What it does

Replaces upstream Frida's "write agent .so into target's address space byte-
by-byte via `ptrace(PTRACE_POKEDATA)`" injection path with: write the .so to
`/data/local/tmp/.yszint-agent-<pid>.so`, then have the target call
`dlopen()` on that path. Two orders of magnitude faster (megabytes-via-poke
becomes a single dlopen) and bypasses Android 16's PTRACE_POKEDATA latency
regression.

The on-disk temp file is a stealth liability — see `D-host-side-unlink.md`
for the unlink invariant.

## Files touched

| File | Why |
|------|-----|
| `src/linux/yszint-helper-backend.vala` | New `bootstrap()` step writes .so to disk; new `temp_file_path` propagation through `BootstrapResult`, `HelperLibcApi`, `HelperLoaderContext` |
| `src/linux/helpers/loader.c` | Target-side: read `temp_file_path` from the loader context, `open()` + `mmap()` instead of receiving bytes via the original write path |
| `src/linux/helpers/include/inject-context.h` | Adds `temp_file_path` field (last position — see ordering note) |

## Invariants

- **temp_file_path must be last in `HelperLoaderContext`** — KP's relocation
  patcher doesn't like late-shifting struct fields. Verified empirically:
  putting it earlier produces SIGBUS during attach (`docs/KNOWN_ISSUES.md`
  used to track this as Bug #1).
- **6 file-I/O fields in `HelperLibcApi` must match `inject-context.h`** —
  `open`, `read`, `write`, `unlink`, `lseek`, `fstat`. Mismatch in any of
  these → loader.c calls a stale function pointer → SIGSEGV.
- **Pre-built loader.bin must be rebuilt** after applying this patch.
  Upstream ships a pre-compiled `src/linux/helpers/artifacts/native/arm64/
  loader.bin` that doesn't know about `temp_file_path`. The build process
  copies that pre-built file verbatim unless you rebuild:
  ```bash
  cd subprojects/frida-core/src/linux/helpers
  FRIDA_HOST=android-arm64 BUILDDIR=$PWD/../../../../build \
      MESON=$PWD/../../../../../releng/meson/meson.py make
  ```
  Without this, the .so binds to the freshly-written `inject-context.h` but
  loader.bin still uses the stale layout → SIGBUS on every attach.

## Verifying after re-apply

After build, the running binary should:

```bash
# Patch is text-level applied
grep -c 'temp_file_path' build-android-arm64/.../yszint-helper-backend.c    # >0

# Loader.bin was rebuilt (file size changes — upstream is ~1478 B,
# patched is ~1578 B)
ls -la build-android-arm64/subprojects/frida-core/src/linux/helpers/artifacts/native/arm64/loader.bin

# Behavioural: an attach() should create then unlink the temp file
# (the unlink is from Patch D, but the create is from Patch A):
ls /proc/<target_pid>/root/data/local/tmp/.yszint-agent-*.so 2>/dev/null   # transient

# Stealth test:
tests/on_device/test_dlopen_temp_file.py    # PASS
```

## Generation

```
git -C subprojects/frida-core format-patch -1 fb1a28f4 --stdout \
    > releng/patches/A-loader-temp-files.patch
```

Source commit: `fb1a28f4 android-16: dlopen agent from /data/local/tmp temp file [SENTINEL]`.

## Drop this patch when

- Android 16's PTRACE_POKEDATA latency regresses again (unlikely) AND the
  bytes-via-poke path becomes faster than dlopen, OR
- We rewrite the loader to use `memfd_create()` (no on-disk file at all)
  — would obsolete both this patch and Patch D.
