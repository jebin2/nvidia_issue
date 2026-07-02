# RTX 4050 Laptop (AD107M) GPU crashes on Linux — full diagnosis & working fix

**TL;DR:** On an Acer Predator Helios Neo 16 (PHN16-71, i7-13700HX + RTX 4050 Laptop) running
CachyOS/Arch, *any* Vulkan workload crashed the NVIDIA GSP firmware (Xid 120), wedging the GPU
until a power cycle — making Steam and every game unusable, while CUDA worked perfectly.
The bug lives in NVIDIA's GPU firmware (GSP *and* PMU), not in the hardware, and it exists in
**both** the 610-open and 580 driver branches.

## The working configuration (2026-07-02)

| Component | Setting |
|---|---|
| Driver | `nvidia-580xx-dkms` / `nvidia-580xx-utils` **580.173.02 (proprietary)** — the 610 branch is open-module-only, and the open module *requires* the buggy GSP firmware |
| GSP firmware | **OFF** — `/etc/modprobe.d/nvidia-gsp-off.conf`: `options nvidia NVreg_EnableGpuFirmware=0` |
| Kernel | LTS (6.18.x). The bleeding-edge 7.1.x kernel additionally broke GPU firmware boot (GFW_BOOT stuck at 0xff) on most boots |
| Clock locks | `nvidia-smi -pm 1; nvidia-smi -lmc 8001; nvidia-smi -lgc 210,1500` — see [`nvidia-clock-lock.service`](nvidia-clock-lock.service) for making it automatic |
| RTD3 | `nvidia.NVreg_DynamicPowerManagement=0` on the kernel cmdline (fixes a separate resume-crash issue) |
| initramfs | Do **not** early-load nvidia (`/etc/mkinitcpio.conf.d/99-no-early-nvidia.conf` with `MODULES=()`) — the 580 modules+firmware bloated the image past what Limine would load (kernel panic `VFS: unable to mount root fs`), and early-loading also makes `modprobe.d` ineffective |

Result: **Hogwarts Legacy plays flawlessly** on the dGPU via Proton (`prime-run %command%`),
99 % GPU utilization, zero Xid errors. CUDA (PyTorch/CTranslate2/faster-whisper) unaffected throughout.

## The three firmware failure modes we isolated

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
   help; **locking the memory clock (`-lmc 8001`) eliminated it completely** — the PMU's memory
   p-state transition machinery is the crashing code, and pinning VRAM frequency means it never runs.

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
- Evidence logs: `nvidia-bug-report-*.log.gz` (healthy baseline / GFW_BOOT failure state) and
  `kernel-log-lts-gsp-crashloop.txt` (8 complete GSP-CrashCat RISC-V core dumps)
- `.nvidia-monitor/` — the stability-monitoring scripts and event log kept during the diagnosis

## Trade-offs of the workaround

- GSP off = the driver manages the GPU from the CPU (NVIDIA's legacy mode; mature and stable).
- `-lmc 8001` keeps VRAM at full clock → a few watts more idle drain while the lock is active.
  The systemd service applies it at boot; disable it (`systemctl disable nvidia-clock-lock`) if
  you need maximum battery and aren't gaming.
- Diagnosed with substantial help from Claude (Anthropic) over a three-day debugging session.
