# RTX 4050 Laptop (AD107M) GPU crashes on Linux — full diagnosis & partial mitigation

> **Update 2026-09-04 — the "working fix" below is only a partial mitigation.**
> Four weeks of further use found three failure modes the clock-lock workaround does not
> cover: a PMU halt at driver init (before any clock can be set), a PMU halt mid-session
> *with* the memory clock verifiably locked, and a silent channel hang that the driver never
> logs an Xid for at all. See failure modes 4–6 below. The original text is kept intact so the
> record shows what was believed and what disproved it. Still reproducing on **580.178.04** and
> kernel **6.18.42-lts**, so driver updates through early September have not addressed it.

**TL;DR:** On an Acer Predator Helios Neo 16 (PHN16-71, i7-13700HX + RTX 4050 Laptop) running
CachyOS/Arch, *any* Vulkan workload crashed the NVIDIA GSP firmware (Xid 120), wedging the GPU
until a power cycle — making Steam and every game unusable, while CUDA worked perfectly.
The bug lives in NVIDIA's GPU firmware (GSP *and* PMU), not in the hardware, and it exists in
**both** the 610-open and 580 driver branches.

## The best known configuration (2026-07-02)

| Component | Setting |
|---|---|
| Driver | `nvidia-580xx-dkms` / `nvidia-580xx-utils` **580.173.02 (proprietary)** — the 610 branch is open-module-only, and the open module *requires* the buggy GSP firmware |
| GSP firmware | **OFF** — `/etc/modprobe.d/nvidia-gsp-off.conf`: `options nvidia NVreg_EnableGpuFirmware=0` |
| Kernel | LTS (6.18.x). The bleeding-edge 7.1.x kernel additionally broke GPU firmware boot (GFW_BOOT stuck at 0xff) on most boots |
| Clock locks | `nvidia-smi -pm 1; nvidia-smi -lmc 8001; nvidia-smi -lgc 210,1500` — see [`nvidia-clock-lock.service`](nvidia-clock-lock.service) for making it automatic |
| RTD3 | `nvidia.NVreg_DynamicPowerManagement=0` on the kernel cmdline (fixes a separate resume-crash issue) |
| initramfs | Do **not** early-load nvidia (`/etc/mkinitcpio.conf.d/99-no-early-nvidia.conf` with `MODULES=()`) — the 580 modules+firmware bloated the image past what Limine would load (kernel panic `VFS: unable to mount root fs`), and early-loading also makes `modprobe.d` ineffective |

Result at the time: **Hogwarts Legacy plays flawlessly** on the dGPU via Proton (`prime-run %command%`),
99 % GPU utilization, zero Xid errors. CUDA (PyTorch/CTranslate2/faster-whisper) unaffected throughout.
This held for several days before modes 4–6 appeared.

## The firmware failure modes we isolated

1. **GSP task crash on Vulkan** (both 610-open and 580-with-GSP): `Xid 120, GSP task exception,
   partition:2#0, task:3`. On 610 the task dies in a tight polling loop reading `0xbadf....`
   poison (an engine that never powered up); on 580 it's a load-address-misaligned exception in
   the same task. Trivial `vkcube` reproduces it; OpenGL and CUDA never trigger it.
2. **Firmware boot failure after a crash** (mostly on kernel 7.1.x): `GSP failed to halt with
   GFW_BOOT (progress 0xff)` + ~50 k poison register reads → `nvidia-smi: No devices were found`.
   Survives warm reboots and sometimes even long power-offs (recovery is a lottery); PCIe link
   stays perfect throughout.
3. **PMU halt during game loads** (580 with GSP off): `Xid 62` (PMU halt) / `Xid 158`
   (FB_FLUSH timeout) around ~2.6 GB VRAM during heavy asset streaming. Core clock caps did NOT
   help; locking the memory clock (`-lmc 8001`) eliminated *this specific* crash — the PMU's memory
   p-state transition machinery is the crashing code, and pinning VRAM frequency means it never runs.
   *(This was originally written as "eliminated it completely". Modes 4–6 disproved that.)*
4. **PMU halt at driver init** (580 with GSP off): `Xid 62` during module load, with a
   **byte-identical fault signature across five separate boots**
   (`3247696a 000147a8 00000000 202b26a8 202b258a 202b1b76 202cc866 202b4ae2`). Follow-on `Xid 158`
   timeouts are attributed to the **udev worker that loads the module** — this happens before any
   graphics client exists, so no clock lock can reach it (the systemd unit fails with
   `System is not in ready state`). Roughly **1 in 3 boots**; needs a full power-off.
   Side effect: `nvidia-smi` reports `WARNING: infoROM is corrupted` — a **false alarm**, it is a
   read failure through a dead PMU and clears on power cycle. Don't RMA over it.
5. **PMU halt mid-session with the memory clock locked** (580 with GSP off): after 10 h of a stable
   session, Halo: MCC triggered `Xid 62 → Xid 45 (all channels, including the compositor's) →
   Xid 154 GPU Reset Required` with `nvidia-smi` confirming `8001 MHz, Enabled`. Once latched,
   every title reports *"Failed to initialise DirectX 12"* until a power cycle.
6. **Silent channel hang with no Xid at all** (580 with GSP off): picture freezes, audio continues,
   desktop stays responsive. `nvidia-smi` shows **100 % utilization at 0 % memory traffic and flat
   idle power** — a context submitted and never retired — while the driver logs *nothing* and never
   attempts recovery. `kill -9` on the game recovers the GPU fully, no reboot needed.
   Reproduced on four unrelated engines (Hogwarts Legacy, Halo: MCC, Batman: Arkham Knight,
   Diablo IV) — still unchanged as of 2026-09-30 on kernel 6.18.52-lts, with both clock locks
   verified applied at the moment of the hang.
   Both clock locks were eliminated as causes by direct experiment — removing them changed nothing
   (time-to-hang scattered randomly between 1.4 and 9.5 min across every configuration tested).
7. **The same dead-on-boot state, silently** (580.178.04, kernel 6.18.42-lts): identical to mode 4 but
   with **no Xid logged at all**. `nvidia-smi` still prints a plausible-looking GPU; the only hint is
   `[System is not in ready state]` where the clocks should be, and the clock-lock unit failing ~10 s
   into boot. So don't trust a log grep to tell you the GPU is healthy — see the health check below.
8. **CUDA/UVM deadlocks unkillably once the GPU is wedged**: with the GPU dead, Steam's
   `d3ddriverquery6` probe enters `uvm_gpu_retain_by_uuid`, takes the UVM global mutex, and spins
   forever in `uvm_spin_loop` waiting on a push that will never retire. Every later probe piles up
   behind it in **uninterruptible D state**, one per launch attempt. `kill -9` does nothing,
   `nvidia-smi` itself wedges, and clean shutdown can stall (use SysRq or hold the power button).
   This is the one failure with **no userspace recovery** — unlike mode 6, where killing the game works.

Common thread: every failure is a **power/engine-management microcontroller** (GSP task 3, GFW/devinit,
PMU) dying around engine power-up or memory p-state work on this VBIOS (95.07.19.00.25). Hardware was
ruled out: 90 s full-power CUDA burn (100 % util, 73 W, 86 °C) with zero faults, and 10 min of OpenGL
rendering clean — plus everything works with the firmware sidestepped.

## Repository contents

- [`GITHUB_ISSUE_DRAFT.md`](GITHUB_ISSUE_DRAFT.md) — the upstream bug report for
  [NVIDIA/open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
- [`NVIDIA_RTD3_FIX.md`](NVIDIA_RTD3_FIX.md) — the earlier RTD3/runtime-PM resume-crash fix
- [`nvidia-clock-lock.service`](nvidia-clock-lock.service) + [`install_clock_lock_service.sh`](install_clock_lock_service.sh) — automatic clock locks at boot
- `driver-580/` — install/rollback scripts for the 610-open ↔ 580-proprietary swap
- `fix_boot.sh`, `fix_boot2.sh` — recovery scripts used when the oversized initramfs broke Limine boot (chroot-from-snapshot pattern)
- `gpu_powercycle.sh` — attempted software D3cold power-cycle of a wedged dGPU (spoiler: a wedged GPU hangs even `modprobe -r`)
- [`gpu-unstick`](gpu-unstick) — recovery helper for the mode-6 silent hang: identifies which failure you are actually in (a kill-recoverable channel hang vs. a PMU halt that needs a power-off), kills the client holding the wedged context while refusing to touch the compositor, then verifies the GPU returned to idle
- Evidence logs: `nvidia-bug-report-*.log.gz` (healthy baseline / GFW_BOOT failure state) and
  `kernel-log-lts-gsp-crashloop.txt` (8 complete GSP-CrashCat RISC-V core dumps)
- `.nvidia-monitor/` — the stability-monitoring scripts and event log kept during the diagnosis

## Trade-offs, and what to actually expect

- GSP off = the driver manages the GPU from the CPU (NVIDIA's legacy mode; mature and stable).
- `-lmc 8001` keeps VRAM at full clock → a few watts more idle drain while the lock is active.
  The systemd service applies it at boot; disable it (`systemctl disable nvidia-clock-lock`) if
  you need maximum battery and aren't gaming.
- **Realistic expectations on this hardware today:** roughly 1 boot in 3 fails with mode 4 and
  needs a full power-off; gaming sessions hang (mode 6) somewhere between 1 and 10 minutes in,
  recoverable with `pkill -9 -f <game>.exe` without rebooting. GL and CUDA remain rock solid
  throughout — this is specifically the graphics/power-management firmware path.
- **Check the GPU is alive before launching anything.** `nvidia-smi` is not a reliable health check —
  it reports a normal-looking GPU in the dead state. This is:
  ```sh
  vulkaninfo --summary >/dev/null 2>&1 && echo "GPU OK" || echo "GPU DEAD — power off"
  ```
  If it says dead, a **full power-off** is the only fix; a warm reboot will not clear it. Launching a
  game anyway just leaks unkillable processes (failure mode 8).
- **If you are on an Optimus laptop, check which GPU your game is actually using** before blaming
  any of the above. Without `prime-run`, DXVK/vkd3d will happily pick the Intel iGPU and the game
  will stutter for entirely unrelated reasons. Launch options that force the dGPU:
  `VKD3D_FILTER_DEVICE_NAME="NVIDIA" DXVK_FILTER_DEVICE_NAME="NVIDIA" prime-run %command%`
- Diagnosed with substantial help from Claude (Anthropic) across several debugging sessions.
