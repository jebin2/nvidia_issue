# TITLE (copy into the GitHub title field):

[AD107M / RTX 4050 Laptop] GSP firmware crashes under Vulkan in BOTH 610.43.02-open and 580.173.02 (same task, partition:2#0 task:3); with GSP disabled, PMU halts (Xid 62) at driver init and mid-session, plus silent channel hangs with no Xid at all; once wedged, CUDA/UVM deadlocks unkillably in `uvm_spin_loop` with no timeout; still present in 580.178.04; no reliable workaround

---

# BODY (copy everything below):

## System
| | |
|---|---|
| Laptop | Acer Predator Helios Neo 16 (PHN16-71), Insyde BIOS V1.13 (09/2023), Optimus hybrid |
| CPU / RAM | Intel Core i7-13700HX / 64 GB |
| iGPU | Intel UHD 770 (8086:4688) — drives the internal display (Wayland, KDE Plasma) |
| dGPU | GeForce RTX 4050 Laptop / Max-Q — **AD107M** (10de:28e1 rev a1), VBIOS **95.07.19.00.25** |
| Driver (modes A–C) | **nvidia-open 610.43.02** (nvidia-utils 610.43.02-3, Arch/CachyOS) |
| Driver (modes D–I) | **nvidia-580xx 580.173.02** and **580.178.04** proprietary (DKMS), `NVreg_EnableGpuFirmware=0` for E–I |
| GSP buildId | `1687a6f9071ccd1eb24e902150aa95df8c420a84` |
| Kernels tested | **7.1.2-cachyos**, **6.18.37/6.18.40/6.18.42-cachyos-lts** (same behaviour) |
| Vulkan loader / Mesa | vulkan-icd-loader 1.4.350.1, mesa 26.1.6 |
| Cmdline | includes `nvidia.NVreg_DynamicPowerManagement=0` (RTD3 fully disabled; runtime PM `active`) |
| Usage model | PRIME render offload (`prime-run`); dGPU has no display attached |

## Summary
Any **Vulkan** use of the dGPU (vkcube, Steam client startup probe `d3ddriverquery64.exe -d3d12` through vkd3d-proton, kwin_wayland's Vulkan probe, or a DX12 game via Proton) crashes the GSP firmware — **in both the 610.43.02 open module and 580.173.02 proprietary-with-GSP, always the same firmware task (`partition:2#0, task:3`)**. **OpenGL and CUDA are completely unaffected** — `prime-run glxgears` ran 10 minutes clean on the same session type that kills vkcube in 1–3 minutes, and CUDA runs heavy sustained loads flawlessly (details below). So the graphics engine itself powers up and renders fine via GL; only the Vulkan path triggers the GSP task hang. The kernel version changes timing/recovery, not the bug. All testing under Wayland (KDE); X11 untested.

**With the GSP disabled (`NVreg_EnableGpuFirmware=0`, proprietary 580) Vulkan works, but the PMU fails instead** (Xid 62 / Xid 158). Locking the memory clock (`nvidia-smi -lmc 8001`) initially appeared to fix this completely and was reported as a workaround. **Two further months of use disproved that** — see modes F, G and H below. The PMU also halts *before any clock can be applied* (at driver init, with a byte-identical fault signature across five separate boots), it halts *mid-session with the memory clock verifiably locked at 8001 MHz*, and there is a third failure where a channel hangs forever and **the driver never logs an Xid at all**. Every observed failure remains in power/engine-management firmware on this VBIOS (95.07.19.00.25), but there is **no configuration known to avoid it**. The CUDA/OpenGL exemption noted above holds only while the GPU is healthy: once the PMU has halted, the UVM layer deadlocks in an unbounded spin (mode I).

**UPDATE 2026-11-03 — MOSTLY RESOLVED BY AN ACER BIOS UPDATE. The GSP faults were a platform-firmware
problem, not an NVIDIA driver bug.** This laptop shipped with BIOS **V1.13 (09/07/2023)** and had never been
updated. Flashing to **V1.20 (05/15/2026)** — which crosses release 1.16, whose Acer release note reads
literally *"NVIDIA GPU settings"* — fixes modes A, D and F outright, with the **VBIOS unchanged at
95.07.19.00.25**. Everything below was observed on the stale BIOS. What the update did NOT fix is the
D3cold/RTD3 resume fault, which still wedges the GPU. See "What BIOS V1.20 changed" near the end.

Anyone hitting this on a Predator PHN16-71 (or likely other Acer Ada laptops) should check
`cat /sys/class/dmi/id/bios_version` before anything else.

**UPDATE 2026-11-02 — the two power-transition faults reproduce under `nouveau`, with no NVIDIA
driver code loaded at all.** Booting a live Arch image (Omarchy 2026.11.02, kernel 7.2.8) that ships
no NVIDIA driver, the same board fails the same way under nouveau + GSP **RM 570.144** (a different
firmware build from the 580.178.04 above): the D3cold resume fault reproduced on 4 of 8 boots and
the init-time halt (mode F) on another, while 3 boots were clean. Same VBIOS, same BIOS, different
driver, different GSP build, newer kernel. Details in the dedicated section below. This removes
NVIDIA's kernel driver from the suspect list and localizes the remaining failures to GSP/PMU
firmware, the VBIOS, and the platform's ACPI power path.

Note the recurring PMU fault word across every Xid 62 on this board — the low 24 bits are constant (`47696a`) while the top byte varies with context:
`6247696a`, `2247696a`, `3247696a`, `0247696a`, `d247696a`.

## Failure mode A — kernel 6.18.37: GSP task watchdog timeout under sustained Vulkan
Firmware boots reliably; short vkcube runs are clean; after **~1–3 min** of sustained rendering (or simply starting the Steam client):

```
GSP task watchdog timeout @ pc:0x109ce80, partition:2#0, task:3, gfid: 0
NVRM: GPU0 kgspHealthCheck_TU102: *** GSP-CrashCat Report ***   (repeats every ~30 s; 8 reports captured in one session)
NVRM: GPU0 _kgspIsHeartbeatTimedOut: Heartbeat timed out ... diff 30001 timeout 5200
NVRM: GPU0 _kgspRpcRecvPoll: GSP RM heartbeat timed out
```

The core dump shows the crashed task is **not corrupted but stuck in a tight polling loop** (PC trace alternates `0x109ceba` ↔ `0x1b6375e` dozens of times; `scause 0x8000000000000005` = timer interrupt), and the local I/O register state contains a **poison read**: `0x01281504: 0xbadf5108` — i.e. the task appears to be polling a register of an engine that never powered up / never left reset. Watchdog PCs observed across occurrences: 0x109ce80, 0x1a9ba44, 0x1577a62, 0x1bc7a5c, 0x1585560, 0x1b63786 — always `partition:2#0, task:3`.

After the crash the driver sometimes recovers (nvidia-smi keeps working, no reset-required); other times nvidia-smi hangs and only a reboot helps.

## Failure mode B — kernel 7.1.2: instant GSP crash at Vulkan device creation
Same triggers, but the GSP dies **within seconds** of `vkCreateDevice`: `Xid 120` (GSP task exception, load-addr-misaligned observed), `Xid 62` (PMU halt), `Xid 154` (PF-FLR), GSP-CrashCat, `rpcSendMessage failed status 0x62 fn 76` → GPU stuck in `NV_ERR_RESET_REQUIRED` ("GPU is probably locked", nvidia-smi `ERR!`). Once wedged, `modprobe -r nvidia` hangs in D-state (no software recovery).

## Failure mode C — kernel 7.1.2: GPU then fails to initialize on subsequent boots
```
NVRM: GPU0 gpuWaitForGfwBootComplete_TU102: GSP failed to halt with GFW_BOOT: (progress 0xff)
NVRM: GPU0 kgspWaitForGfwBootOk_TU102: failed to wait for GFW boot complete: 0x65
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x62:0x65:2119)
+ ~50,000 lines: gpuHandleSanityCheckRegReadError_GM107: addr 0x110100, regvalue 0xbadf5720
```
→ `nvidia-smi: No devices were found`. **The PCIe link stays perfect throughout** (16 GT/s x8, config space readable, BARs mapped) — only the firmware/devinit stage fails. Note the same `0xbadf....` poison-read family as failure mode A. Recovery is **non-deterministic**: one warm reboot cleared it once; a 5-hour power-off plus a 60-second power-button drain did NOT. On 2026-07-02, kernel 7.1.2 failed every boot attempt while kernel 6.18.37 initialized the GPU on the first try (identical driver) — though 6.18 also hit this once when rebooting from a wedged state.

## What works (hardware, thermals, power ruled out)
- **OpenGL is fine:** `prime-run glxgears` rendered continuously for ~10 minutes on the dGPU with zero NVRM/GSP messages — same boot, same session type where vkcube kills the GSP in 1–3 minutes.
- **CUDA is rock solid:** 90 s full-power burn (PyTorch fp16 8192² matmuls, 100 % util, 73 W, peak 86 °C) with zero faults; CTranslate2/faster-whisper inference works daily. Compute classes fine, graphics classes fatal — consistent with the poison-read/engine-power-up theory above.
- 14 h desktop session with zero NVRM messages (as long as nothing touches graphics classes on the dGPU).
- Locking clocks (`nvidia-smi -lgc 210,1500`) does not prevent the crash → not a clock/power transient.

## Failure mode D — 580.173.02 proprietary WITH GSP: instant GSP crash on enumeration
Swapping to the proprietary 580 branch (GSP firmware enabled, its default) made it *worse*: mere
`vulkaninfo` enumeration killed the GSP within a second:
```
Xid 120, name=vulkaninfo, GSP task exception: load address misaligned (cause:0x4) @ pc:0x1ba0e50, partition:2#0, task:3
```
Same partition and task as the 610 crashes — the bug is in the GSP firmware family for this chip,
not in one driver branch.

## Failure mode E — 580.173.02 with GSP DISABLED: PMU halt during heavy VRAM streaming
With `NVreg_EnableGpuFirmware=0` (RM on CPU), Vulkan works: vkcube runs indefinitely, Steam is fine.
But loading a AAA game (Hogwarts Legacy via vkd3d-proton) reproducibly died at ~2.6 GB VRAM:
```
Xid 62 (PMU halt), e.g.: 6247696a 00000009 00000000 2028aff2 20288e70 2028f20c 2028f5ce 2028f746
Xid 158 - timeout error waiting for NV_UFLUSH_FB_FLUSH = 0x3
Xid 45 (all channels) → Xid 154 GPU Reset Required
```
Core clock caps (`-lgc 210,1500`, even 1200) did **not** prevent it. Locking the memory clock
(`nvidia-smi -lmc 8001`) did: the same game then loaded fully and played at 99 % GPU utilization,
37 W, 77 °C, **zero Xids**, and continued to do so for several days.

> **CORRECTION (2026-08-01).** The memory clock lock is **not** a reliable workaround. It holds for
> this specific load-time crash, but modes **F**, **G** and **H** below all occur with the lock
> applied and verified. The original text of this section overstated the result and is retained
> here only to show what the lock does and does not cover.

## Failure mode F — GSP off: PMU halts at driver init, before any clock can be applied
The most serious mode, because **no workaround can reach it** — the PMU dies while the module is
loading, so `nvidia-smi -lmc 8001` has not run yet and cannot run (the clock-lock systemd unit
fails with `System is not in ready state`, exit 255). Observed on **five separate boots**, with a
**byte-identical fault signature**:

```
Jul 03 02:24:53  Xid 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
Jul 03 02:24:53  Xid 62,  3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b4ae2
Jul 24 10:06:03  Xid 154 → Reset Required
Jul 24 10:06:04  Xid 62,  3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b4ae2
Jul 24 19:44:08  Xid 62,  3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b4ae2
Jul 25 10:36:12  Xid 62,  3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b492c
Jul 25 10:51:52  Xid 62,  3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b4ae2
```

Only the final word varies (`202b4ae2` / `202b492c`); the first seven are identical every time,
which suggests a deterministic path rather than a race. That this is pre-userspace is confirmed by
the follow-on timeouts being attributed to **the udev worker that loads the module**:

```
Jul 24 19:45:09  Xid 158, pid=616, name=(udev-worker), - timeout error waiting for NV_UFLUSH_FB_FLUSH = 0x2
Jul 24 19:46:09  Xid 158, pid=616, name=(udev-worker), ...   (repeats every 60 s)
```

On 2026-07-25 the GPU died **12 seconds into boot**, ~3 s after module load and ~7 s *before* the
compositor started — so no graphics client existed. Consequence: `nvidia-smi` reports
`System is not in ready state`, power reads `ERR!`, and the infoROM is reported as corrupt
(`WARNING: infoROM is corrupted at gpu 0000:01:00.0`). **That infoROM warning is a false alarm** —
it is absent from every healthy log, present only while the PMU is halted, and disappears after a
power cycle. It is an infoROM *read failure through a dead PMU*, not EEPROM damage. Worth fixing
separately, as it will cause users to RMA healthy boards.

Recovery requires a full power-off; a warm reboot frequently reproduces it immediately. In one
stretch, **4 of 6 consecutive boots** failed this way.

### Variant: the same dead-on-boot state with *no Xid logged at all* (580.178.04, 2026-09-04)

Boot at 18:34:41 on 580.178.04 / kernel 6.18.42-lts produced an identical end state with a
**completely empty kernel log** — `journalctl -k -b 0 | grep "NVRM: Xid"` returns nothing. The only
trace anywhere in the system that something went wrong is the clock-lock unit failing 10 seconds
into boot:

```
ExecStart=/usr/bin/nvidia-smi -pm 1        status=0/SUCCESS
ExecStart=/usr/bin/nvidia-smi -lmc 8001    status=255/EXCEPTION
Active: failed since Fri 2026-09-04 18:34:51 IST
```

`nvidia-smi -pm 1` succeeding and `-lmc 8001` failing one second later brackets the moment the PMU
went away. From then on the GPU is unusable but *looks* healthy to a casual check — no warning
banner, no infoROM message, no Xid:

```
$ nvidia-smi --query-gpu=utilization.gpu,memory.used,clocks.gr,clocks.mem --format=csv,noheader
0 %, 2 MiB, [System is not in ready state], [System is not in ready state]

$ vulkaninfo --summary
ERROR: terminator_CreateDevice: Failed in ICD libGLX_nvidia.so.580.178.04 vkCreateDevice call
ERROR at vulkaninfo.h:1864: vkCreateDevice failed with ERROR_INITIALIZATION_FAILED
```

Forcing the Intel ICD works normally, so the Vulkan stack itself is fine. **`vulkaninfo --summary`
returning `ERROR_INITIALIZATION_FAILED` is the cheapest reliable detector for this state** — far
more reliable than `nvidia-smi`, which reports a plausible-looking GPU. Applications surface it as
a driver problem and send users to reinstall drivers that are not at fault; the Vulkan client under
test reported *"needs a Vulkan-capable GPU and up-to-date graphics drivers, and could not find one
on this system."*

The important part for triage: **mode F does not always announce itself.** Any log-based detection
keyed on Xid 62 will miss this variant entirely.

## Failure mode G — GSP off: PMU halts mid-session WITH the memory clock locked
Directly contradicts the mode-E workaround. After 10 h 25 m of a stable session, a *different*
title (Halo: The Master Chief Collection, an unrelated engine to Hogwarts Legacy) triggered a full
PMU halt cascade. `nvidia-smi` confirmed `8001 MHz, Enabled` — the lock was applied and active:

```
Jul 25 22:59:46  Xid 62, d247696a 000043c8 00000000 202c5ad4 202c04d0 202bf55e 2026f9ca 202c21d4
Jul 25 22:59:46  Xid 45, pid=58583, name=MCC-Win64-Shipp, channel 0x08 / 0x0c / 0x0d / 0x0f
Jul 25 22:59:46  Xid 45, pid=1783,  name=kwin_wayland,    channel 0x23 / 0x27 / 0x28 / 0x2a / 0x2b / 0x30
Jul 25 22:59:46  Xid 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
```

The teardown takes the compositor's channels with it. Once latched into `GPU Recovery Action:
Reset`, every subsequent context creation fails, which surfaces to the user as **"Failed to
initialise DirectX 12. Graphics driver may require an update"** from any title, not just the one
that crashed. Only a power cycle clears it.

## Failure mode H — GSP off: silent channel hang, no Xid logged at all
The hardest to diagnose, and arguably the worst driver-side behaviour: the GPU stops retiring work
and **the driver never notices**. No Xid, no timeout, no recovery attempt, indefinitely.

Signature while hung (stable for 10+ minutes, sampled every 2 s):

```
utilization.gpu     100 %      ← reported busy
utilization.memory    0 %      ← zero memory-controller traffic
power.draw         14.9 W      ← flat to ±0.1 W
GPU Recovery Action : None
kernel Xid          (none)
```

100 % utilization with 0 % memory traffic and flat idle-level power means nothing is executing —
a context is submitted and never completes. Userspace blocks behind it:

```
BatmanAK.exe      S  ntsync_char_ioctl
RenderingThread   S  futex_wait      ← waiting on a GPU fence that never signals
dxvk-cs           S  futex_wait
```

Audio continues (CPU-side), the window freezes, and the desktop stays fully responsive — the
compositor is on the iGPU and unaffected. `kill -9` on the game recovers the GPU completely, with
no reset required and no reboot.

**Reproduced across four unrelated engines:** Hogwarts Legacy (UE4), Halo: MCC, Batman: Arkham
Knight (UE3) and Diablo IV, all via vkd3d-proton/DXVK under PRIME offload. In Hogwarts it sometimes
escalates to an Xid 109 after several minutes; in Arkham Knight it never logged anything in 6
observed hangs.

Still reproducing unchanged on **2026-09-30**, kernel 6.18.52-lts, on a boot where the clock locks
applied cleanly and **no Xid was logged all session**. Diablo IV, captured while hung:

```
utilization.gpu     100 %      ← reported busy
utilization.memory    0 %      ← zero memory-controller traffic
power.draw         12.01 W     ← idle, against a ~101 W cap
memory.used        5597 MiB    ← game still holding VRAM
temperature          64 C
clocks.gr / clocks.mem   1500 MHz / 8001 MHz   ← both locks verified applied
kernel Xid          (none)
```

`pkill -9` on the game returned the GPU to `0 %, 20 MiB, 210 MHz` immediately, no reset and no
reboot. Note the locks were **verified applied at the moment of the hang** — further confirmation
that mode H is independent of the clock-lock workaround, and that ten months of driver updates
(580.173.02 → 580.178.04) and kernel updates (6.18.37 → 6.18.52) have not touched it.

```
Jul 02 11:49:06  Xid 109, pid=5745,  name=HogwartsLegacy., channel 0x3c, CTX SWITCH TIMEOUT, Info 0x2ac015
Jul 25 13:13:58  Xid 109, pid=9911,  name=HogwartsLegacy., channel 0x14, CTX SWITCH TIMEOUT, Info 0x11c00e
Jul 25 13:27:56  Xid 109, pid=14242, name=HogwartsLegacy., channel 0x14, CTX SWITCH TIMEOUT, Info 0x11c00e
```

**Systematically eliminated as causes** (each tested by direct experiment on 2026-08-01, Arkham
Knight, time-to-hang measured):

| Configuration | Time to hang |
|---|---|
| Baseline (`-lmc 8001`, `-lgc 210,1500`) | 9.5 min |
| `DXVK_FRAME_RATE=60` frame cap | 4.7 min |
| `DXVK_FRAME_RATE=60` frame cap (repeat) | 6.0 min |
| Graphics clock lock removed (`-rgc`, ran free to 2460 MHz) | 3.5 min |
| **Both** clock locks removed (`-rgc` + `-rmc`) | 1.4 min |

Random scatter with no correlation to any variable. Core clock floor (`-lgc 900,1500`) was also
tested separately and made no difference. **Neither clock lock is implicated in this mode, and
neither prevents it.**

## Failure mode I — GSP off: CUDA/UVM deadlocks unkillably once the GPU is wedged, with no timeout
Observed 2026-09-04 on **580.178.04** / kernel 6.18.42-lts, on a machine already in the silent
mode-F state described above. This is a **driver-side** bug and is independent of whatever the
firmware did first.

With the GPU unresponsive, Steam's GPU-enumeration helper (`d3ddriverquery6`) enters UVM and never
returns. The first invocation takes the UVM global mutex and then spins forever inside
`uvm_spin_loop`, waiting on a push that the dead GPU will never retire:

```
task:d3ddriverquery6 state:R   pid:15514        ← holds the mutex, spinning in kernel mode
  uvm_spin_loop
  wait_for_entry_with_spin
  uvm_tracker_wait_for_entry
  uvm_push_end_and_wait
  channel_pool_add
  uvm_channel_manager_create
  uvm_gpu_semaphore_pool_create
  uvm_gpu_retain_by_uuid
  uvm_va_space_register_gpu
  uvm_api_register_gpu
  uvm_unlocked_ioctl
```

Every later invocation then piles up behind that mutex in **uninterruptible D state**:

```
INFO: task d3ddriverquery6:17492 blocked for more than 122 seconds.
      Tainted: P           OE       6.18.42-1-cachyos-lts #1
INFO: task d3ddriverquery6:17492 is blocked on a mutex likely owned by task d3ddriverquery6:15514.
  __mutex_lock
  uvm_gpu_retain_by_uuid
  uvm_va_space_register_gpu
  uvm_api_register_gpu
  uvm_unlocked_ioctl
```

Repeating at 122 / 245 / 368 seconds and continuing indefinitely. After 30 minutes:

```
PID    STAT  ELAPSED  WCHAN                   COMMAND
15514  R<s   29:45    -                       d3ddriverquery6
17492  D<s   28:43    uvm_gpu_retain_by_uuid  d3ddriverquery6
18987  Ds    27:33    uvm_gpu_retain_by_uuid  d3ddriverquery6
19861  Ds    26:37    uvm_gpu_retain_by_uuid  d3ddriverquery6
```

Consequences:

- **`kill -9` cannot clear any of this.** The D-state tasks do not take signals, and the lock holder
  is spinning in kernel mode where it never checks for them. Unlike mode H — where killing the game
  fully recovers the GPU — there is no userspace recovery at all.
- **Each retry leaks another permanently stuck process.** A user who tries to launch a game three
  more times ends up with three more unkillable tasks.
- **`nvidia-smi` itself wedges** into D state once this has happened, so the standard diagnostic
  hangs rather than reporting.
- **Clean shutdown may stall**, because systemd cannot reap the stuck tasks; SysRq or a forced
  power-off is required.

### This is confirmed in the shipped source, not inferred

`nvidia-uvm` ships as source in the DKMS tree, so the behaviour above can be read directly.
From **`nvidia-uvm/uvm_common.c:249`** (580.178.04):

```c
NV_STATUS uvm_spin_loop(uvm_spin_loop_t *spin)
{
    NvU64 curr = NV_GETTIME();
    ...
    cpu_relax();

    // TODO: Bug 1710855: Also check fatal_signal_pending() here if the caller can handle it.

    if (curr - spin->print_time_ns >= 1000*1000*1000*UVM_SPIN_LOOP_PRINT_TIMEOUT_SEC) {
        spin->print_time_ns = curr;
        return NV_ERR_TIMEOUT_RETRY;
    }

    return NV_OK;
}
```

**There is no absolute timeout.** `NV_ERR_TIMEOUT_RETRY` is a periodic *retry* signal, not an abort,
and the wrapper macro in `uvm_common.h:288` treats it purely as a diagnostic:

```c
#define UVM_SPIN_LOOP(__spin) ({
    NV_STATUS __status = uvm_spin_loop(__spin);
    if (__status == NV_ERR_TIMEOUT_RETRY) {
        UVM_DBG_PRINT("Warning: stuck waiting for %llus\n", ...);
        if (uvm_debug_prints_enabled())
            dump_stack();
    }
    __status;
})
```

So callers spin forever by construction. Worse, the only diagnostic UVM offers is behind
`uvm_debug_prints_enabled()`, which is off in production builds — which is why the kernel log for
mode I contains the kernel's own `hung_task` traces and **nothing at all from UVM**, despite UVM
being the component that is stuck.

The `kill -9` immunity is explained by the same function: the `TODO` on the line above notes that
`fatal_signal_pending()` is **not** checked here. A task spinning in `uvm_spin_loop` never looks to
see whether it has been killed. Both TODOs reference **Bug 1710855**, so this is a known gap.

A GPU that has stopped retiring work is exactly the case an upper bound exists for, and CUDA/UVM was
otherwise the one path on this board that never misbehaved — so this converts a graphics-firmware
fault into an unrecoverable system-wide one.

## The power-transition faults reproduce under nouveau (no NVIDIA driver loaded)

Tested from a live Arch image (Omarchy 2026.11.02) that ships **no NVIDIA driver** — only
`linux-firmware-nvidia`. Kernel `7.2.8-9-omarchy`, driver `nouveau`, **GSP RM version 570.144**,
same board, same `VBIOS 95.07.19.00.25`, same BIOS V1.13.

Across 8 boots: 3 clean, 4 ended in the D3cold resume fault, 1 failed to probe at all.

### A healthy boot looks completely normal

```
pci 0000:01:00.0: optimus capabilities: enabled, status dynamic power
nouveau: detected PR support, will not use DSM
nouveau 0000:01:00.0: NVIDIA AD107 (197000a1)
nouveau 0000:01:00.0: gsp: RM version: 570.144
nouveau 0000:01:00.0: bios: version 95.07.19.00.25
nouveau 0000:01:00.0: drm: VRAM: 6141 MiB
[drm] Initialized nouveau 1.4.2 for 0000:01:00.0 on minor 0
```

### Then it runtime-suspends and does not come back

The GPU enters D3cold while idle. The next access — any of `lspci` reading config space, a kworker,
or a write to `power/control` — triggers a resume that times out in the GSP RPC layer:

```
WARNING: drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r535/rpc.c:164
         at r535_gsp_msg_recv+0x461/0x550 [nouveau], CPU#4: lspci/2156
  r535_gsp_rpc_send   -> r535_gsp_rpc_push -> r535_gsp_rpc_rm_ctrl_push
  -> r570_fbsr_resume -> r535_gsp_init     -> nvkm_subdev_init
  -> nvkm_device_init -> nouveau_do_resume -> nouveau_pmops_runtime_resume
nouveau 0000:01:00.0: disp: init failed, -110
nouveau 0000:01:00.0: drm: Client resume failed with error: -110
nouveau 0000:01:00.0: timeout
```

`-110` is `ETIMEDOUT`: the GSP never answers after the power transition. In the worst case the
device then leaves the PCI bus entirely and no longer appears in `lspci` at all.

**This is the same fault that `NVreg_DynamicPowerManagement=0` works around on the proprietary
driver** — the workaround avoids D3cold rather than fixing the transition.

Note the mechanism nouveau reports: `detected PR support, will not use DSM` means it reaches D3cold
through **ACPI `_PR3` Power Resources**, which are defined by the platform firmware, not by the
driver. The driver requests the transition; BIOS-supplied ACPI methods execute it.

### Mode F reproduces too — GSP fails at probe, attributed to `(udev-worker)`

On one boot the GPU never came up at all, with the fault again attributed to a udev worker exactly
as in mode F above:

```
WARNING: .../gsp/rm/r535/rpc.c:164  at r535_gsp_msg_recv, CPU#22: (udev-worker)/815
         ... r535_gsp_init+0x250/0x990
WARNING: .../gsp/rm/r535/gsp.c:300  at r535_gsp_init+0x6a0/0x990, CPU#9: (udev-worker)/815
nouveau 0000:01:00.0: gsp: init failed, -110
nouveau 0000:01:00.0: sec2(gsp):booter-unload: boot failed: -110
nouveau 0000:01:00.0: probe with driver nouveau failed with error -110
```

Only `card1` (i915) registered; nouveau never bound.

### And a third state: bound, but GSP rejecting control calls continuously

```
nouveau 0000:01:00.0: gsp: cli:0xc1d00001 obj:0x00730000 ctrl cmd:0x00731341 failed: 0x0000ffff
   (x65 within one second)
```

### What this establishes

| Variable | Varied across tests | Fault persists |
|---|---|---|
| Host driver | NVIDIA 610-open, NVIDIA 580-proprietary, **nouveau** | yes |
| GSP firmware build | 580.178.04, **570.144** | yes |
| Kernel | 6.18.37/.42/.52/.55, 7.1.2, **7.2.8** | yes |
| Distribution | CachyOS, **Omarchy** | yes |
| VBIOS | 95.07.19.00.25 (unchanged — not alterable from the OS) | — |
| System BIOS | V1.13, 09/07/2023 (unchanged) | — |

Modes A–D and H were **not** retested here: the live image ships no Vulkan driver and the GPU
suspended before a load test could be completed, so nothing is claimed about them under nouveau.

## What BIOS V1.20 changed (tested 2026-11-03)

Updated the system BIOS from the factory **V1.13 (09/07/2023)** to **V1.20 (05/15/2026)**, crossing these
Acer releases:

| Version | Date | Acer's release note |
|---|---|---|
| 1.16 | 2024/04/29 | **"NVIDIA GPU settings"** |
| 1.18 | 2024/09/20 | boot logo customization |
| 1.20 | 2026/06/23 | Microsoft 2023 Secure Boot certificates |

**The VBIOS did not change** — still `95.07.19.00.25` before and after. So whatever was fixed lives in the
platform's ACPI and power tables, not in the graphics BIOS.

Retested on 580.178.04 with **GSP ENABLED** (`EnableGpuFirmware: 18`), the configuration that was unusable
for four months:

| Mode | On BIOS V1.13 | On BIOS V1.20 |
|---|---|---|
| **D** — GSP crash on enumeration | `vulkaninfo` crashed the GSP instantly, Xid 120, every attempt | enumerates clean, exit 0, no Xid |
| **A** — GSP task watchdog under sustained Vulkan | vkcube died in 1–3 min | **360 s continuous, zero faults**, GPU responsive after |
| **F** — PMU halt at driver init | ~1 boot in 3, byte-identical signature | 4 consecutive clean boots |
| **RTD3 / D3cold resume** | GPU fails to resume, falls off the bus | **STILL BROKEN — unchanged** |

### The D3cold resume fault survives the BIOS update

With `NVreg_DynamicPowerManagement` left at its default (`DynamicPowerManagement: 3`), persistence mode off
and no clock locks, the GPU idles into D3cold and does not come back:

```
$ nvidia-smi --query-gpu=name,pstate,power.draw --format=csv
NVIDIA GeForce RTX 4050 Laptop GPU, [GPU requires reset], [N/A]
```

`nvidia-smi` blocks for over two minutes before returning that. Recovery needs a full power-off.

This is consistent with the nouveau findings above: nouveau reaches D3cold through ACPI `_PR3` Power
Resources (`detected PR support, will not use DSM`), and that path is still wrong on V1.20.

### Current working configuration — one workaround instead of three

```
# still required:
options nvidia NVreg_DynamicPowerManagement=0

# NO LONGER required on BIOS V1.20:
#   NVreg_EnableGpuFirmware=0      (GSP now works)
#   nvidia-smi -lmc 8001 / -lgc    (clock locks were for mode E)
```

Running with GSP enabled is the supported configuration, and it now works on this board.

## Other drivers tried
- **595.71.05 open (DKMS):** cannot initialize AD107M on kernel 7.1 (same 0xbadf5720 flood → "No devices").
- `pcie_aspm=off`: made initialization worse. (No proprietary build exists for the 610 branch.)
- **`nouveau` + GSP RM 570.144 on kernel 7.2.8:** reproduces the D3cold resume fault and the
  init-time GSP halt — see the dedicated section above. No NVIDIA driver code involved.

## Best known configuration (partial mitigation only — NOT a fix)
```
# proprietary 580 branch, GSP off:
/etc/modprobe.d/nvidia-gsp-off.conf:  options nvidia NVreg_EnableGpuFirmware=0
                                      options nvidia NVreg_DynamicPowerManagement=0
# pin memory clocks (and optionally cap core):
nvidia-smi -pm 1; nvidia-smi -lmc 8001; nvidia-smi -lgc 210,1500
```
**What this buys:** it avoids modes A–D entirely (no GSP, so no GSP crash) and prevents the mode-E
crash during heavy VRAM streaming at game load. That is genuinely worth having.

**What it does not do:** it cannot prevent mode **F** (the PMU is already dead before the clock
commands can run), it does not prevent mode **G** (halt occurred with the lock verified active),
and it has no effect whatsoever on mode **H** (proven by direct removal — the hang happens with the
locks on, with only the graphics lock removed, and with both removed).

The practical state for a user on this hardware is: boot failures roughly 1 in 3, requiring a
full power-off; and a gaming session that hangs after somewhere between 1 and 10 minutes,
recoverable with `kill -9`. `NVreg_DynamicPowerManagement=0` is separately required to fix an
RTD3 resume crash on this laptop.

Full write-up, scripts and logs: https://github.com/jebin2/nvidia_issue

## Reproduction (100 % reliable)
1. Kernel 6.18.37 + nvidia-open 610.43.02, GPU healthy (nvidia-smi OK, zero NVRM messages).
2. `prime-run vkcube` — or just start the Steam client.
3. Within ~0.5–3 min: GSP task 3 watchdog timeout → CrashCat loop → heartbeat timeout.

On kernel 7.1.2 the same step crashes the GSP within seconds, then frequently cascades into failure mode C on subsequent boots.

### Reproduction for mode H (GSP off, ~100 % within 10 min)
1. Proprietary 580.173.02, `NVreg_EnableGpuFirmware=0`, kernel 6.18.40-lts.
2. `nvidia-smi -pm 1; nvidia-smi -lmc 8001; nvidia-smi -lgc 210,1500` (or omit — makes no difference).
3. Launch any DX11/DX12 title through Proton with `prime-run` (three unrelated engines confirmed).
4. Within 1–10 min the picture freezes while audio continues. `nvidia-smi` shows 100 % utilization,
   0 % memory utilization, flat idle power, **no Xid, no recovery action**. `kill -9` recovers.

### Reproduction under nouveau (no NVIDIA driver needed)
Boot any current live Arch image that ships no NVIDIA driver (tested: Omarchy 2026.11.02, kernel
7.2.8), let the dGPU idle into D3cold, then touch it:

```
lspci -nn | grep 10de          # or simply wait for any access
dmesg | grep -iE 'nouveau|gsp'
```

Expect `r535_gsp_msg_recv` warnings from `rpc.c:164`, `disp: init failed, -110`, and the device
vanishing from `lspci`. Roughly 1 boot in 2 on this board. `nouveau.runpm=0` avoids it, which is
the nouveau equivalent of `NVreg_DynamicPowerManagement=0`.

## Attachments
- `nvidia-bug-report-healthy.log.gz` — healthy baseline (6.18.37, before any Vulkan)
- `nvidia-bug-report-vkcube-crash.log.gz` — right after a short (still clean) vkcube run
- `kernel-log-lts-gsp-crashloop.txt` — full kernel log: sustained vkcube + Steam start → GSP task-watchdog crash loop with complete CrashCat RISC-V core dumps (6.18.37)
- `nvidia-bug-report-gfwboot-fail.log.gz` — failure mode C captured live (7.1.2)
- `nvidia-bug-report-gsp-crashcat-lts.log.gz` — GSP CrashCat report (6.18-lts)

## Ask
Please investigate the GSP/PMU firmware's engine power-up and memory p-state handling for AD107M
(VBIOS 95.07.19.00.25). GL and CUDA running flawlessly on the same board shows the silicon is
fine and localizes the failure to the graphics/power-management firmware paths.

**Scope note after the BIOS update:** modes A, D and F were platform-firmware bugs and are fixed by Acer
BIOS 1.16+. The requests below now concern (a) the D3cold resume fault, which the BIOS update did NOT fix,
and (b) the driver-side robustness issues, which are independent of any firmware and still stand.

Requests, in priority order:

1. **~~Mode F is the blocker.~~ FIXED by Acer BIOS 1.16+.** Left here for the record: the PMU halted during module init with a byte-identical fault
   signature across five boots, before any user configuration can be applied. There is no
   workaround available at that point in time, and it costs a full power-off. The determinism of
   the signature should make it tractable.
2. **Mode H is a driver bug independent of the firmware fault.** A channel hangs forever and the
   RM never times it out, never raises an Xid, and never attempts recovery — the GPU simply reports
   100 % busy at 0 % memory traffic indefinitely. Even if the underlying hang is a firmware issue,
   the driver should detect and report it. Right now it is invisible to every diagnostic.
3. **`uvm_spin_loop` needs an upper bound and a signal check (mode I) — see Bug 1710855.**
   `nvidia-uvm/uvm_common.c:249` has no absolute timeout: `NV_ERR_TIMEOUT_RETRY` is a diagnostic
   retry, and `UVM_SPIN_LOOP` only logs it behind `uvm_debug_prints_enabled()`. So when the GPU
   stops retiring pushes, UVM spins forever holding the global mutex, every subsequent
   `uvm_api_register_gpu` piles up in uninterruptible D state, and the in-tree `TODO` explains the
   `kill -9` immunity — `fatal_signal_pending()` is not checked. Bounding the wait and honouring
   fatal signals would turn an unrecoverable system hang into a normal ioctl failure.
4. **The D3cold resume path needs looking at below the driver.** It now reproduces under nouveau
   with a different GSP build, so it is not a bug in NVIDIA's kernel driver. On this board nouveau
   reaches D3cold via ACPI `_PR3` Power Resources (`detected PR support, will not use DSM`), so the
   sequence spans GSP firmware, the VBIOS and BIOS-supplied ACPI — any of which could be at fault,
   and none of which is reachable from the OS. If this is a known-bad platform/VBIOS combination,
   saying so publicly would save a lot of people a lot of time.
5. **The false infoROM-corruption warning** (mode F) should be suppressed when the PMU is
   unresponsive. It is a read failure through dead firmware, not EEPROM damage, and it will send
   users to RMA perfectly healthy boards.

Happy to test debug builds, module parameters (`NVreg_EnableGpuFirmwareLogs`, registry dwords), or
updated GSP firmware. The vkcube reproduction (GSP enabled) and the mode-H game reproduction (GSP
disabled) are both reliable, and I can capture whatever traces are useful.
