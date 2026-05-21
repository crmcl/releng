# Patch D — Host-side unlink of /data/local/tmp/.yszint-agent-*.so

## What it does

Closes the stealth gap left open by Patch A: after a successful
`launch_loader()` (the agent is dlopen'd and mmap'd into the target),
the host side (yszint-server, running as shell uid) unlinks the temp
file from `/data/local/tmp/`. The file is gone from disk but the
mmap'd code is unaffected.

## Why this is a separate patch from A

Patch A's loader.c (target-side, runs as untrusted_app uid) tries to
unlink the temp file after dlopen. On Android 16 that fails silently
with EACCES because `/data/local/tmp` is `drwxrwx--x shell:shell` and
untrusted_app has traverse but no write. We didn't notice this for
weeks because forensic invariants are only visible to scans, not to
behavioral tests.

Host-side unlink succeeds because yszint-server runs as shell uid,
which DOES have write to /data/local/tmp.

## Files touched

| File | Lines | Why |
|------|-------|-----|
| `src/linux/yszint-helper-backend.vala` | +18 | After `launch_loader()` returns, unlink `/proc/<pid>/root<temp_file_path>` |

## Invariants

- **Logical dependency on Patch A.** Patch D references
  `temp_file_path` which is propagated through `BootstrapResult` by
  Patch A. Without Patch A, `temp_file_path` doesn't exist as a field
  and the patch won't compile.
- **No-op if `temp_file_path.length == 0`** — defensive coding for
  paths where Patch A might not have populated the field (legacy
  injection paths, future loader work that bypasses temp file).
- **Best-effort.** The unlink uses `try { } catch { }` swallowing all
  errors. If the unlink fails for any reason, the file leaks but the
  attach still succeeds. We log nothing because false-positive logs
  (e.g., the loader.c-side unlink raced ahead and succeeded → host-side
  EEXIST → loud error in dmesg) are noisier than helpful.
- **Path construction uses `/proc/<pid>/root`** — this is the Linux
  way to access another process's filesystem namespace from outside.
  Required because target might have a different mount namespace
  (Zygote isolation).

## Verifying after re-apply

```bash
# Source-level
grep 'host_unlink_path' subprojects/frida-core/src/linux/yszint-helper-backend.vala
# → should print one match (the FileUtils.unlink call)

# Behavioural — 4 cycles, all clean:
for i in 1 2 3 4; do
    python3 -c "
import frida, sys, subprocess, time
sys.path.insert(0, '/home/yami/0005/yszint/subprojects/frida-python')
dev = frida.get_device_manager().add_remote_device('127.0.0.1:5233')
pid = int(subprocess.check_output(['adb', 'shell', 'pidof', 'com.android.systemui']))
s = dev.attach(pid); s.detach(); print('cycle ok')"
done
adb shell 'ndkctl -c "ls /data/local/tmp/.yszint-agent-*.so 2>&1"'
# → 'No such file or directory'  (good)
```

## Generation

This patch is hand-crafted: the original commit `5b09a4f5` accidentally
captured rebuild artifacts (loader.bin, bootstrapper.bin, zymbiote.elf)
plus stealth-script re-applies in `compat/build.py`, `embed-*.py`, etc.
The clean Patch D contains only the logical change in
`yszint-helper-backend.vala`.

To regenerate cleanly from a future commit:
```
git -C subprojects/frida-core show <commit> \
    -- src/linux/yszint-helper-backend.vala \
    > /tmp/D.diff
# Then prepend the From/Subject/commit-message header (see this file's
# patch for the template) and use `git am`.
```

## Drop this patch when

- Patch A is dropped (no more temp file → nothing to unlink), OR
- Patch A is rewritten to use `memfd_create()` (no on-disk file at all
  — obsoletes both A's temp-file aspect AND D entirely).
