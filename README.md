# Linux Idle Freeze Guard

**Your Linux machine freezes when you leave it alone? The NVIDIA GPU is entering a power state it can't wake up from.**

## The Root Cause: D3cold

After extensive troubleshooting, we found the actual root cause: the NVIDIA GPU enters **D3cold** (deep sleep), a PCI power state from which the proprietary NVIDIA driver cannot reliably recover. When the GPU fails to wake, the display server hangs waiting for it, and your entire graphical session freezes.

The fix is a single udev rule that prevents the GPU from entering D3cold:

```bash
# /etc/udev/rules.d/80-nvidia-pm.rules
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{d3cold_allowed}="0"
```

This project wraps that fix with diagnostics, additional defensive layers, monitoring, and recovery tools.

## Quick Start

```bash
git clone https://github.com/olympus-terminal/linux-idle-freeze-guard.git
cd linux-idle-freeze-guard

# Step 1: Diagnose (checks D3cold status, GPU, power settings, logs)
./scripts/diagnose.sh

# Step 2: Apply all fixes (D3cold + sleep/suspend/DPMS layers)
sudo ./scripts/fix.sh

# Step 3 (optional): Monitor for regressions after package updates
sudo ./scripts/install-monitor.sh
```

## What's In the Box

| Script | What it does |
|---|---|
| `scripts/diagnose.sh` | Checks D3cold state, GPU hardware, drivers, power settings, and system logs |
| `scripts/fix.sh` | Disables D3cold (primary) + idle suspend/sleep at every level (defensive) |
| `scripts/recover.sh` | Restart the display manager from TTY without rebooting |
| `scripts/install-monitor.sh` | Systemd timer + package hooks to auto-repair if settings get reverted |
| `scripts/uninstall.sh` | Clean removal of all modifications |

## How the Fix Works

The fix operates at multiple layers. **Layer 0 is the one that actually solves the problem.** Layers 1-5 are defense-in-depth to prevent the system from even attempting to trigger the GPU power transition.

### Layer 0: D3cold (the actual fix)

A udev rule that fires when the NVIDIA GPU is added to the PCI bus:
- Sets `d3cold_allowed=0` — prevents the GPU from entering the deepest PCI power state
- Sets `power/control=on` — keeps the GPU powered at all times

This is applied via `/etc/udev/rules.d/80-nvidia-pm.rules` and survives reboots. The fix script also applies it immediately to the running system.

### Layer 1: Systemd Targets

Masks `sleep.target`, `suspend.target`, `hibernate.target`, and `hybrid-sleep.target` so the kernel cannot enter sleep states at all.

### Layer 2: Logind Configuration

Drop-in config at `/etc/systemd/logind.conf.d/freeze-guard.conf`:
- `HandleLidSwitch=ignore` (and variants)
- `IdleAction=ignore`

### Layer 3: Desktop Environment (GNOME/KDE)

System-level dconf overrides with **locks** so package updates and GUI settings cannot re-enable sleep:
- Sleep on AC/battery: disabled
- Screen idle timeout: disabled
- Screensaver: disabled
- Lid close action: nothing

### Layer 4: DPMS (Display Power Management)

Xorg config to disable DPMS entirely — prevents the display from being powered off by X11.

### Layer 5: NVIDIA Persistence

Enables `nvidia-persistenced` to keep the GPU initialized even when no display client is active.

## The Evolution

This project evolved through three phases of debugging:

1. **[eyes-wide-open](https://github.com/olympus-terminal/eyes-wide-open)** (archived) — First attempt. Disabled sleep/suspend at the systemd, logind, and GNOME levels. Helped reduce frequency but didn't eliminate freezes because the GPU could still enter D3cold via other paths.

2. **linux-idle-freeze-guard v1** — Added more layers: dconf locks, DPMS override, nvidia-persistenced, regression monitoring. More robust but still treating symptoms.

3. **D3cold discovery** — Found that the GPU entering D3cold (PCI deep sleep) was the actual root cause. A single udev rule disabling D3cold eliminated the freezes entirely. The other layers remain as defense-in-depth.

## Who Is Affected?

Primarily systems with:
- NVIDIA GPUs (discrete or hybrid Intel/NVIDIA, AMD/NVIDIA)
- Proprietary NVIDIA drivers (nouveau is generally not affected)
- Linux kernels that support runtime PM and D3cold for PCI devices
- Laptops are highest risk (hybrid GPU + lid switch + aggressive power management)

## Recovery

If your display is frozen right now:

1. Press `Ctrl+Alt+F4` to switch to a text console (try F3-F6 if F4 doesn't work)
2. Log in with your username and password
3. Run: `sudo systemctl restart gdm` (or `sddm` / `lightdm`)
4. Press `Ctrl+Alt+F1` or `Ctrl+Alt+F2` to switch back to the graphical session

Or use the recovery script:
```bash
./scripts/recover.sh
```

**Note:** GUI app unsaved work is lost, but terminal sessions, tmux/screen, background processes, and SSH connections survive.

## Supported Distributions

| Distro | Desktop | Status |
|---|---|---|
| Ubuntu 22.04+ | GNOME | Fully supported |
| Ubuntu 24.04+ | GNOME | Fully supported |
| Fedora 38+ | GNOME | Supported |
| Arch Linux | GNOME | Supported |
| Linux Mint | Cinnamon | Supported |
| KDE (any distro) | KDE Plasma | Supported |

## Verification

After applying the fix:

```bash
# Check D3cold is disabled (should show 0)
cat /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed

# Check udev rule exists
cat /etc/udev/rules.d/80-nvidia-pm.rules

# Run full diagnostics
./scripts/diagnose.sh
```

## Contributing

If you've experienced this issue on a distribution or hardware not listed above, please open an issue with:
- Your distro and version
- Desktop environment
- NVIDIA driver version (`nvidia-smi`)
- Output of `./scripts/diagnose.sh`

## License

MIT
