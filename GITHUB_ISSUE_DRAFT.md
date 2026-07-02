# TITLE (copy into the GitHub title field):

[AD107M / RTX 4050 Laptop] GSP firmware crashes under Vulkan in BOTH 610.43.02-open and 580.173.02 (same task, partition:2#0 task:3); OpenGL/CUDA unaffected; working workaround found: proprietary + EnableGpuFirmware=0 + locked memory clocks

---

# BODY (copy everything below):

## System
| | |
|---|---|
| Laptop | Acer Predator Helios Neo 16 (PHN16-71), Insyde BIOS V1.13 (09/2023), Optimus hybrid |
| CPU / RAM | Intel Core i7-13700HX / 64 GB |
| iGPU | Intel UHD 770 (8086:4688) — drives the internal display (Wayland, KDE Plasma) |
| dGPU | GeForce RTX 4050 Laptop / Max-Q — **AD107M** (10de:28e1 rev a1), VBIOS **95.07.19.00.25** |
| Driver | **nvidia-open 610.43.02** (nvidia-utils 610.43.02-3, Arch/CachyOS) |
| GSP buildId | `1687a6f9071ccd1eb24e902150aa95df8c420a84` |
| Kernels tested | **7.1.2-cachyos** and **6.18.37-cachyos-lts** (same driver on both) |
| Vulkan loader / Mesa | vulkan-icd-loader 1.4.350.1, mesa 26.1.3 |
| Cmdline | includes `nvidia.NVreg_DynamicPowerManagement=0` (RTD3 fully disabled; runtime PM `active`) |
| Usage model | PRIME render offload (`prime-run`); dGPU has no display attached |

## Summary
Any **Vulkan** use of the dGPU (vkcube, Steam client startup probe `d3ddriverquery64.exe -d3d12` through vkd3d-proton, kwin_wayland's Vulkan probe, or a DX12 game via Proton) crashes the GSP firmware — **in both the 610.43.02 open module and 580.173.02 proprietary-with-GSP, always the same firmware task (`partition:2#0, task:3`)**. **OpenGL and CUDA are completely unaffected** — `prime-run glxgears` ran 10 minutes clean on the same session type that kills vkcube in 1–3 minutes, and CUDA runs heavy sustained loads flawlessly (details below). So the graphics engine itself powers up and renders fine via GL; only the Vulkan path triggers the GSP task hang. The kernel version changes timing/recovery, not the bug. All testing under Wayland (KDE); X11 untested.

**A working workaround was found (see bottom), which also localizes the bug:** with the GSP disabled (`NVreg_EnableGpuFirmware=0`, proprietary 580) Vulkan works, but game-load-class workloads then crash the **PMU** instead (Xid 62 / Xid 158) — until the **memory clock is locked** (`nvidia-smi -lmc 8001`), after which everything is fully stable (a AAA game runs at 99 % utilization with zero Xids). Every observed failure is therefore in power/engine-management firmware around engine power-up and memory p-state transitions on this VBIOS (95.07.19.00.25).

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
Core clock caps (`-lgc 210,1500`, even 1200) did **not** prevent it. **Locking the memory clock
did:** `nvidia-smi -lmc 8001` → the same game loads fully and plays at 99 % GPU utilization,
37 W, 77 °C, **zero Xids**. This strongly suggests the PMU's memory p-state transition path is
the crashing code, consistent with the GSP task-3 poison-read polling in failure mode A.

## Other drivers tried
- **595.71.05 open (DKMS):** cannot initialize AD107M on kernel 7.1 (same 0xbadf5720 flood → "No devices").
- `pcie_aspm=off`: made initialization worse. (No proprietary build exists for the 610 branch.)

## Current working workaround (for other affected users)
```
# proprietary 580 branch, GSP off:
/etc/modprobe.d/nvidia-gsp-off.conf:  options nvidia NVreg_EnableGpuFirmware=0
# pin memory clocks (and optionally cap core):
nvidia-smi -pm 1; nvidia-smi -lmc 8001; nvidia-smi -lgc 210,1500
```
Full write-up, scripts and logs: https://github.com/jebin2/nvidia_issue

## Reproduction (100 % reliable)
1. Kernel 6.18.37 + nvidia-open 610.43.02, GPU healthy (nvidia-smi OK, zero NVRM messages).
2. `prime-run vkcube` — or just start the Steam client.
3. Within ~0.5–3 min: GSP task 3 watchdog timeout → CrashCat loop → heartbeat timeout.

On kernel 7.1.2 the same step crashes the GSP within seconds, then frequently cascades into failure mode C on subsequent boots.

## Attachments
- `nvidia-bug-report-healthy.log.gz` — healthy baseline (6.18.37, before any Vulkan)
- `nvidia-bug-report-vkcube-crash.log.gz` — right after a short (still clean) vkcube run
- `kernel-log-lts-gsp-crashloop.txt` — full kernel log: sustained vkcube + Steam start → GSP task-watchdog crash loop with complete CrashCat RISC-V core dumps (6.18.37)
- `nvidia-bug-report-gfwboot-fail.log.gz` — failure mode C captured live (7.1.2)

## Ask
Please investigate the GSP/PMU firmware's engine power-up and memory p-state handling for AD107M
(VBIOS 95.07.19.00.25). The workaround proves the silicon is fine and precisely which firmware
paths fail. Happy to test debug builds, module parameters (`NVreg_EnableGpuFirmwareLogs`,
registry dwords), or updated GSP firmware — the vkcube reproduction (with GSP enabled) is fully reliable.
