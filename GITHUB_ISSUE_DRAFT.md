# TITLE (copy into the GitHub title field):

[AD107M / RTX 4050 Laptop, Acer PHN16-71] VRAM test fails on one repeating data bit; random GSP and PMU faults on Linux (Xid 62/119/120) and nvlddmkm errors with BSOD 0x10E at idle on Windows: can this be anything but a failing board?

---

# BODY (copy everything below):

## System
| | |
|---|---|
| Laptop | Acer Predator Helios Neo 16 (PHN16-71), Insyde BIOS V1.13 (09/2023; V1.20 from 2026-11-03), Optimus hybrid |
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

**UPDATE 2026-11-03 — THE GPU ALSO FAILS ON WINDOWS, AT IDLE. This may not be a Linux or GSP bug.** On a clean
Windows 11 install with NVIDIA driver 621.01 and no game or stress test running, Windows logged 353
`nvlddmkm` Event 14 errors in one second, `UCodeReset TDR occurred on GPUID:100`, and a `0x10E` blue screen.
`nvidia-smi` on Windows reports `GSP Firmware Version: N/A`. See "The GPU also fails on Windows".

**A VRAM test also fails.** `memtest_vulkan` found 4 single-bit errors at 4 different addresses, at both 8001 and 7001 MHz, and every
one is bit 23. See "VRAM test".

Updating the BIOS from **V1.13 (09/07/2023)** to **V1.20 (05/15/2026)**, with the **VBIOS unchanged at
95.07.19.00.25**, did not fix this. Light vkcube runs now survive, but on V1.20 and current drivers the
Linux side still shows GSP watchdog timeouts, GSP exceptions and panics, GSP RPC timeouts and PMU halts. Everything
further down was observed on V1.13 unless it says otherwise, and conclusions written there about the
silicon being fine or the fault lying in GSP firmware predate this evidence. A failing GPU board is now a leading
suspect, alongside VBIOS or platform firmware. Software testing cannot separate those.

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

## What worked on the old BIOS (this does NOT rule out hardware; see the 2026-11-03 update)
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

This resembles the resume fault that `NVreg_DynamicPowerManagement=0` works around on the proprietary
driver, though the shared cause is inferred from the symptom. These nouveau runs were all on BIOS V1.13.

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

**The VBIOS did not change** — still `95.07.19.00.25` before and after. Only V1.20 was tested, so this does
not show which release made the difference. The 1.16 note is suggestive, not proof, and the V1.13 ACPI tables
were not dumped, so there is no before/after table diff.

### Every boot on V1.20, from the kernel journal

| Boot (2026-11-03) | Driver | GSP | RTD3 | Clock locks | Result |
|---|---|---|---|---|---|
| 05:03 | 580.178.04 | off | off (`DPM=0`) | on | no Xid |
| 05:15 | 580.178.04 | **on** | off (`DPM=0`) | on | `vulkaninfo` clean, vkcube 360 s, no Xid |
| **05:25** | 580.178.04 | **on** | default, D3cold allowed | **off** | **wedged: Xid 119 ×3, Xid 154** |
| 05:35 | 580.196.07 | on | default, `d3cold_allowed=0` | on | no Xid in 13 min |
| **05:48** | 615.78.08 | on | default, `d3cold_allowed=0` | never applied | **GSP init failed at probe** |
| 05:50 | 615.78.08 | on | default, `d3cold_allowed=0` | on | no Xid, Steam and vkcube running, 25 min |
| **06:15** | 615.78.08 | on | default, `d3cold_allowed=0` | none (fails before they could apply) | **GSP task watchdog at probe, Xid 119 ×2** |
| **06:17** | 615.78.08 | on | default, `d3cold_allowed=0` | off | clean for about 4 h 45 min including 10 min of vkcube, then **Xid 62 PMU halt 7 s after Steam started** |
| **11:24** | 615.78.08 | on | default, `d3cold_allowed=0` | off | **Xid 120 GSP exception 34 s after Steam started** |
| **11:39** | 615.78.08 | on | default, `d3cold_allowed=0` | none (fails before they could apply) | **Xid 120 GSP kernel panic at probe**, after a clean power-off |
| 12:12 | 615.78.08 | on | default, `d3cold_allowed=0` | off | no Xid in 8 min, no Steam |
| 12:22 | 615.78.08 | on | default, `d3cold_allowed=0` | off | no Xid in 7 min, no Steam |
| 12:31 | 615.78.08 | on | default, `d3cold_allowed=0` | off | no Xid in 3 min, no Steam |
| 12:50 | 615.78.08 | on | default, `d3cold_allowed=0` | on from 12:55 | no Xid in 7 min |
| 12:58 | 615.78.08 | on | default, `d3cold_allowed=0` | on | no Xid at 3 min, Steam just started |

Tallies, all small samples:

- **Failed at probe:** 615.78.08 on 3 of 11 boots; 580 on 0 of 4.
- **Faulted after probe:** with clock locks off, 3 of 7 boots, two of them right after Steam started; the four clean ones were short and did not start Steam. With locks on, 0 of 6 boots, all short and none with a game. Clock locks cannot affect a probe failure, because they apply after the driver starts.
- **Boot type does not separate these:** the 11:24 and 11:39 failures both followed a clean power-off.

Limits of this record:

- **vkcube is a light load** (about 11 W). No game has been run on V1.20, so modes E, G, H and I are untested.
- **Mode F is barely retested in its own configuration.** It was a PMU halt with GSP off, and only the 05:03
  boot matches that. A PMU halt did recur at 06:17 with GSP on.
- **The Steam trigger:** `steam.desktop` sets `PrefersNonDefaultGPU=true`, so the whole client and its Vulkan and D3D12
  startup probes ran on the dGPU. A local override now keeps Steam on Intel. That is a workaround, and it is not yet tested with a game.
- The journal rotated during the day, so kernel logs from the earliest boots survive only as the excerpts here.

### The 05:25 failure: GSP stopped answering, and it does not look like a D3cold resume

```
05:27:10 NVRM: Xid 119, pid=793, name=nvidia-powerd, Timeout after 45s of waiting for RPC response
         from GPU0 GSP! Expected function 76 (GSP_RM_CONTROL) sequence 2974 ...
05:27:55 NVRM: Xid 119, Timeout after 45s ... sequence 2975 (0x2080a0d1 0x7e8)
05:28:40 NVRM: Xid 119, Timeout after 45s ... sequence 2976 (0x2080a0d1 0x7e8)
05:28:40 NVRM: Xid 154, GPU recovery action changed from 0x0 (None) to 0x1 (GPU Reset Required)
```

`nvidia-smi` then reported `[GPU requires reset]`. The three 45 s timeouts add up to 135 s, which fits the
two-minute-plus block seen from `nvidia-smi`.

This was first read as "the GPU idled into D3cold and did not come back". The driver's RPC history in the same
report points the other way:

- The last good RPC completed normally **0.3 s** before the one that hung.
- The most recent `GSP_RUN_CPU_SEQUENCER` event was **48 s** earlier, about when the driver first started.
- So the GSP looks awake and in service when it stopped responding, about 48 s after start, while
  `nvidia-powerd` was polling it. This assumes a resume would log a newer sequencer event. Nothing directly
  recorded the PCI power state.

That boot differed from the clean ones in three ways at once: clock locks off, persistence off and D3cold
allowed. A single run cannot separate them. **So there is currently no confirmed D3cold resume failure on
BIOS V1.20.** The confirmed D3cold-style failures are the nouveau runs on V1.13. D3cold on V1.20 still needs a
test in which the GPU is shown to have suspended first.

### Probe failures on 615.78.08

```
05:48  GspMsgQueueReceiveStatus: MCTP protocol violation: invalid vendor ID 0xfffe (expected 0x10de)
       kgspSendInitRpcs_IMPL: GMCAPI_CMD_GSP_INIT failed: 0x25
       _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
       RmInitAdapter failed! (0x62:0x40:2130)
06:15  GSP task watchdog timeout @ pc:0x1905c90, partition:2#0, task:3, gfid: 0
       Local I/O registers include 0x01281504:0xbadf510c
       Xid 119, name=nv-probe-0000:0, Timeout after 6s of waiting for RPC response from GPU0 GSP!
11:39  Xid 120, name=nv-probe-0000:0, GSP kernel panic: unhandled trap (12) @ pc:0xffffffff93004156, partition:2#0
       RmInitAdapter failed! (0x23:0x62:1284)
```

### Faults after probe on 615.78.08

```
11:03:54  Xid 62, 6251c5ee 20013d2a 00000000 202b8ecc 202b9604 00000000 00000000 00000000
          _kgspRpcGspEventPmuHalted: Received signal from GSP that PMU has halted.
          Xid 154, GPU recovery action changed from 0x0 (None) to 0x1 (PF FLR)
          Xid 45, pid=1943, name=kwin_wayland (6 channels)
11:26:16  Xid 120, GSP task exception: load address misaligned (cause:0x4) @ pc:0x14148b8, partition:2#0, task:3
          Xid 154, GPU recovery action changed from 0x0 (None) to 0x1 (PF FLR)
```

The GSP build here is `bae8003ffd51fd740c5a1e4776d6e52e50582125`, not the older build listed above. Crash type and
address both vary, which looks unlike a single deterministic code bug, though it does not prove a hardware cause.

## The GPU also fails on Windows

Windows 11 (build 26100) dual-booted on the same machine, BIOS V1.20, VBIOS 95.07.19.00.25, no GPU stress test or game
running. `nvidia-smi` reported driver 621.01 and `GSP Firmware Version: N/A`. Times are IST, converted because the Windows clock
was wrong until 12:36.

| Time | Event |
|---|---|
| 11:58 | Blue screen `0x1000007E`, access violation (`0xC0000005`) in `ntoskrnl`. Driver probably still 528.25. May be unrelated to the GPU |
| 12:21:54 | **353 × `nvlddmkm` Event 14**, plus Event 153 `UCodeReset TDR occurred on GPUID:100` |
| 12:29 | Blue screen `0x10E` `VIDEO_MEMORY_MANAGEMENT_INTERNAL`, parameters `0x17`, `0xC00002B6` (`STATUS_DEVICE_REMOVED`) |
| 12:38:34 | Event 153 `Error occurred on GPUID: 100` |
| 12:40–12:46 | Four restarts with the GPU healthy |

The repeated Event 14 data was:

```
3254d09c 00016080 00000000 202f073c 202f061e 202efc12 2030adc2 202f2c7a
```

That has the same eight-word shape as the Linux Xid 62 data above, and a shape match is not proof of the same fault.

**What this suggests:** the fault reproduces across Windows, NVIDIA's Linux drivers and (for the startup and resume failures) nouveau, so
the constants are the board, its VBIOS and the platform firmware. Windows reporting GSP as N/A means GSP cannot be the whole
explanation. It is also consistent with the PMU halts seen on Linux with GSP disabled.

**What was not tested:**

- FurMark and game tests on Windows were not run. The failures above happened without them.
- System RAM has not been tested, and could be relevant to the `0x7E` crash.
- The Linux Btrfs volume reports `corrupt 3473968372` at mount with no checksum failures in retained logs. The counter may be stale or damaged, and has not been checked with a scrub.
- No manufacturer GPU diagnostic has been run. The next step is Acer service.

## VRAM test: one data bit keeps failing

`memtest_vulkan` v0.5.0 on Linux, driver 615.78.08, core limited to 1500 MHz, GPU core 72–78 °C, memory temperature not reported. 8001 MHz is this
board's stock maximum, and the board has no ECC. No Xid was logged during either run.

| Memory clock | Duration | Address | Bit | Value read |
|---|---|---|---|---|
| 8001 MHz | about 22 min, error at about 4.5 min | `0x11F05D050` | 23 | `0x2BB329F5` |
| 7001 MHz | about 2 min, all three errors in about the first minute | `0x275810B8` | 23 | `0x05B609E6` |
| 7001 MHz | | `0xBD988CB0` | 23 | `0x91B7AA10` |
| 7001 MHz | | `0xA7BBBA28` | 23 | `0x45BFDDF2` |

The tool's verdict at 8001 MHz was `Standard 5-minute test fail - ERRORS FOUND`.

All four errors are a single flipped bit, always bit 23, always read as 1, at four different addresses. By chance, four errors would share one
of 32 bit positions about 1 time in 32,768. That suggests one weak data line, memory chip or memory-controller path rather than
one bad cell or an excessive clock. Lowering the clock did not help, though the sample is too small to compare error rates.

The test does not show that these flips cause the GSP and PMU faults, though corrupted VRAM could produce faults that vary in type and
address. It also cannot separate the memory chips from the GPU's memory controller or the board.

## ACPI analysis of the D3cold path: a real firmware defect, not shown to be the cause

Decompiled from the machine's tables on V1.20 (`iasl -d`, SSDT12, OEM `ACRSYS`/`ACRPRDCT`). `PEG1` exposes one
power resource, `\_SB.PC00.PEG1.PXP`, as both `_PR0` and `_PR3`. nouveau logs `detected PR support, will not
use DSM` on this board, which puts this resource on its D3cold path. In `PXP._ON`:

```asl
PON ()
L23D ()
Local0 = Zero
While ((\_SB.PC00.PEG1.CULS != \_SB.PC00.PEG1.TRLS))
{
    If ((Local0 > 0x20))
    {
        Break
    }

    Sleep (0x10)
    Local0++
}

\_SB.PC00.PEG1.CMDR = 0x07
\_SB.PC00.PEG1.D0ST = Zero
While ((\_SB.PC00.PEG1.PEGP.NVID != 0x10DE))
{
    Sleep (One)
}
```

and in `PON`, which runs first:

```asl
While ((\_SB.GGIV (\_SB.PC00.PEG1.PEGP.PWGD) == Zero))
{
    If ((Local0 > 0x20))
    {
        Debug = "PON: Time Out waiting PWOK ON"
        Break
    }

    Sleep (One)
    Local0++
}
```

**What the code establishes:**

- The wait for the GPU's vendor ID has **no bound**. If the GPU never answers, the AML itself never exits.
- The link-speed wait (about 530 ms) and the power-good wait (about 33 ms at minimum `Sleep`) both `Break` and
  carry on, with no failure recorded, so a timeout there leads straight into the unbounded wait.

**Why it is not shown to cause the failures here:**

- **Linux bounds the loop anyway.** ACPICA aborts any AML `While` after `ACPI_MAX_LOOP_TIMEOUT` (30 s) with
  `AE_AML_LOOP_TIMEOUT` (`drivers/acpi/acpica/dscontrol.c`), so a stuck loop should leave that error in the log.
  **It appears nowhere:** not in the 8 retained journal boots and not in the archived nouveau dmesg captures,
  which include the resume failures.
- **The nouveau trace fails later than this code.** It times out in `r570_fbsr_resume` under
  `nouveau_pmops_runtime_resume`. The PCI core powers the device up before that driver callback, so `_ON` had
  already returned.
- **The 05:25 failure** is explained by GSP RPC timeouts, with no ACPI error logged.
- **The branch taken is unknown.** `_ON` skips this code when `GSTA` reports power-good already up, and takes a
  GC6 path (`GC6O`) when `TDGC == 1`. Neither value was read at runtime.

The loop is worth fixing as a robustness defect: without ACPICA's limit, it could hang the OS on a GPU that fails
to return. The evidence so far points at the GSP not answering after a transition, not at this loop.

A patched SSDT12 that bounds the loop and widens both waits compiles with `iasl` (0 errors), but it was **never
loaded or tested**. The evidence does not justify deploying it. Loading it through the initrd table upgrade is
also not straightforward: all 18 SSDTs share one OEM ID and table ID, and `acpi_table_initrd_override()` matches
on those plus a higher `oem_revision`, taking the first candidate. A single override table would therefore go to
the wrong SSDT or be skipped.

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

## Reproduction (on BIOS V1.13; intermittent on V1.20)
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
Could someone who can read the fault data tell us whether this is a known firmware problem or points at failing
hardware? The GPU faults on Linux and at idle on Windows, across driver branches, and the words above may decode that quickly.

**Scope note:** this board may turn out to be faulty, in which case the firmware requests below may not apply to it. The driver-side
robustness requests are independent of the cause and still stand.

Requests, in priority order:

0. **Decode the fault data, alongside the VRAM test result.** Do Windows Event 14 `3254d09c 00016080 ...` and Linux Xid 62 `6251c5ee 20013d2a ...` report the same PMU fault, and does the pattern point at the board? Is there a diagnostic an owner can run to tell?

1. **Mode F: this exact init-time PMU signature has not recurred on V1.20, in limited testing.** On the old BIOS, the PMU halted during module init with a byte-identical fault
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
4. **Why does the GSP stop answering, on V1.13 resume and on V1.20 with clock locks off?** The nouveau resume
   failure (V1.13, GSP RM 570.144) and the V1.20 Xid 119 wedge (580.178.04) both end with the GSP not answering
   RPCs, though they may not share a cause. If this is a known-bad platform/VBIOS combination, saying so publicly
   would save a lot of people a lot of time. Separately, Acer's `PXP._ON` has an unbounded wait, documented above
   as a firmware robustness defect rather than an established cause.
5. **The false infoROM-corruption warning** (mode F) should be suppressed when the PMU is
   unresponsive. It is a read failure through dead firmware, not EEPROM damage, and it will send
   users to RMA perfectly healthy boards.

Happy to test debug builds, module parameters (`NVreg_EnableGpuFirmwareLogs`, registry dwords), or
updated GSP firmware, and I can capture whatever traces are useful. Failures on V1.20 are intermittent rather than
reliably reproducible, so captures may take several boots.
