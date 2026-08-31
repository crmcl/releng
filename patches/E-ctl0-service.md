# Patch E — persistent ctl0 service

**Status:** implemented, built, deployed, and validated on yszint 17.17.0.

Patch E exposes the KernelPatch ctl0 supercall over Frida's existing `ServiceSession`
channel. Clients can issue KPM commands without spawning `adb shell`, `ndkctl`, and
`kpatch` for every operation.

## Dependency and files

E is split into two mbox files and must apply in order:

1. `E-ctl0-service-gum.patch` after Patch C
   - exports `gum_yszint_kpm_ctl0()` from `gum/gumyszintshadow.{c,h}`
2. `E-ctl0-service-core.patch`
   - primes the server process's KPM superkey from `YSZINT_SUPERKEY`
   - adds `src/linux/yszint-ctl0-service.vala`
   - wires `open_service("yszint-ctl0")` through `linux-host-session.vala`
   - adds the service source to Meson

## Client API

```python
svc = dev.open_service("yszint-ctl0")
r = svc.request({
    "type": "ctl0",
    "module": "yszint-stealth",
    "verb": "status",
})
# {"ok": True, "ret": 0, "reply": "OK status\n..."}
svc.cancel()
```

Request fields:
- `type`: exactly `ctl0`
- `module`: KPM module name, maximum 64 bytes
- `verb`: raw ctl0 command, maximum 1024 bytes

Replies contain `ok`, raw signed `ret`, and the KPM `reply`. Malformed requests throw
`Error.INVALID_ARGUMENT`; per-request errors do not destroy the reusable service session.

## Superkey model

The server must be launched with `YSZINT_SUPERKEY=Penner103` in its real environment.
`server-glue.c` calls `gum_yszint_shadow_init()` in the server process, which stores the
per-process superkey used by this service. No injected agent and no
`Interceptor.enableShadow()` call are required for client ctl0 requests.

Agent-side shadow operations are separate: an injected target process must call
`Interceptor.enableShadow("Penner103")` because the server's process-local key does not
propagate into the target.

## Validation

Five tests cover Patch E:
- Routine: `test_ctl0_service_handshake.py`, `test_ctl0_service_invalid_params.py`,
  `test_ctl0_service_no_agent.py`, `test_ctl0_service_request_reuse_after_error.py`
- Stress: `test_ctl0_service_high_rate.py`

Basic service operation is validated on Pixel 10 Pro / Android 16: `status` and
`target=<pid>,watchdog` succeed, followed by a 17.17 client attach. The 10,000-call
high-rate stress test is a **known failing contract** as of 2026-08-30: it can close the
client transport and wedge subsequent forwarding until server/forward reset. Keep it
outside routine validation and treat it as a Patch E reliability issue.
