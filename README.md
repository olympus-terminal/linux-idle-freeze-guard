# Linux Idle Freeze Guard

**Your Linux machine freezes when you leave it alone? You're not alone.**

This is a common problem on Linux systems with NVIDIA GPUs (especially laptops with both Intel and NVIDIA graphics). Here's what's happening:

1. You walk away from your computer
2. Linux tries to put your display to sleep or suspend the system
3. The NVIDIA driver fails to wake the display back up
4. Your screen is frozen — mouse doesn't move, keyboard doesn't respond
5. You're forced to hold the power button and lose your work

This project provides tools to **diagnose**, **fix**, **recover from**, and **monitor** this issue.

## Quick Start

```bash
git clone https://github.com/YOUR_USERNAME/linux-idle-freeze-guard.git
cd linux-idle-freeze-guard

# Step 1: Find out if you're affected
./scripts/diagnose.sh

# Step 2: Apply the fix
sudo ./scripts/fix.sh

# Step 3 (optional): Install a monitor that alerts you if settings get reverted
sudo ./scripts/install-monitor.sh
```

## What's In the Box

| Script | What it does |
|---|---|
| `scripts/diagnose.sh` | Checks your hardware, drivers, power settings, and system logs for signs of this issue |
| `scripts/fix.sh` | Disables idle suspend/sleep at every level, locked so package updates can't revert it |
| `scripts/recover.sh` | Instructions and commands to recover without rebooting when a freeze happens |
| `scripts/install-monitor.sh` | Installs a systemd timer that checks for settings regressions after package updates |

## The Problem in Detail

### Who is affected?

Primarily systems with:
- NVIDIA GPUs (discrete or hybrid Intel/NVIDIA, AMD/NVIDIA)
- Proprietary NVIDIA drivers (nouveau is generally not affected)
- GNOME, KDE, or other desktop environments that enable idle suspend by default

### What actually happens?

When your system goes idle, several things can trigger a display freeze:

1. **GNOME/KDE idle timeout** — the desktop environment blanks the screen and may trigger DPMS (Display Power Management Signaling)
2. **Systemd suspend** — the system tries to enter a low-power sleep state
3. **Screen locker activation** — the screensaver/lock screen powers off the display

Any of these can cause the NVIDIA driver to put the GPU into a power state it can't recover from. The display server (Xorg or Wayland) then hangs waiting for the GPU, and your entire graphical session becomes unresponsive.

### Why does it keep coming back?

Even if you disable suspend, **package updates can silently re-enable it**. When `gnome-settings-daemon` or similar packages are updated via `apt`, `dnf`, or `pacman`, they can reset your power management settings to their defaults — which include auto-suspend. This means the problem can reappear after any system update without warning.

This project solves that by locking settings at the system level and monitoring for regressions.

### It's not a full system crash

Here's the good news: **your system is still running**. Only the display is frozen. Your programs, files, and background processes are fine. If you can get to a text console (see [Recovery](#recovery)), you can restart just the display manager and get back to work without rebooting.

## Recovery

If your display is frozen right now:

1. Press `Ctrl+Alt+F4` to switch to a text console (try F3-F6 if F4 doesn't work)
2. Log in with your username and password
3. Run: `sudo systemctl restart gdm` (or `sddm` / `lightdm` depending on your setup)
4. Press `Ctrl+Alt+F1` or `Ctrl+Alt+F2` to switch back to the graphical session

**Note:** This will close your graphical apps (unsaved work in GUI apps will be lost), but terminal sessions, background processes, and anything in `tmux` or `screen` will survive.

Or just run:
```bash
./scripts/recover.sh
```

## Supported Distributions

| Distro | Desktop | Status |
|---|---|---|
| Ubuntu 22.04+ | GNOME | Fully supported |
| Ubuntu 24.04+ | GNOME | Fully supported |
| Fedora 38+ | GNOME | Supported |
| Arch Linux | GNOME | Supported |
| Linux Mint | Cinnamon | Supported |
| KDE (any distro) | KDE Plasma | Supported |

## How It Works

### The Fix

The fix script disables idle suspend and screen blanking at **every level** of the stack:

1. **dconf (system-level)** — writes settings to `/etc/dconf/db/local.d/` so they survive user resets and package updates
2. **systemd targets** — masks `sleep.target`, `suspend.target`, `hibernate.target`, and `hybrid-sleep.target`
3. **logind.conf** — sets `HandleLidSwitch=ignore` and related options
4. **DPMS** — disables display power management

### The Monitor

The monitor installs a systemd timer that runs after every package upgrade. It checks whether any power management settings have been reverted to dangerous defaults and either:
- Fixes them automatically, or
- Sends a desktop notification warning you

## Contributing

If you've experienced this issue on a distribution or desktop environment not listed above, please open an issue with:
- Your distro and version
- Desktop environment
- NVIDIA driver version (`nvidia-smi`)
- Output of `./scripts/diagnose.sh`

## License

MIT

## Related Issues

- [NVIDIA Linux Driver Bug Reports](https://forums.developer.nvidia.com/c/gpu-graphics/linux/148)
- [Ubuntu Bug: gnome-settings-daemon resets power settings](https://bugs.launchpad.net/ubuntu/+source/gnome-settings-daemon)
- [Arch Wiki: NVIDIA/Troubleshooting](https://wiki.archlinux.org/title/NVIDIA/Troubleshooting)
