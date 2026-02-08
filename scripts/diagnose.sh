#!/bin/bash
# ============================================================================
# Linux Idle Freeze Guard - Diagnostic Script
# ============================================================================
# This script checks your system for conditions that cause display freezes
# after idle periods, particularly on NVIDIA GPU systems.
#
# Run: ./diagnose.sh
# No root required (but some checks are more detailed with root).
# ============================================================================

set -u

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

warn_count=0
risk_count=0

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; warn_count=$((warn_count + 1)); }
risk()  { echo -e "${RED}[RISK]${NC} $1"; risk_count=$((risk_count + 1)); }
header() { echo; echo -e "${BOLD}=== $1 ===${NC}"; }

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║       Linux Idle Freeze Guard - Diagnostics      ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Distro Detection ──────────────────────────────────────────────────────────

header "System Information"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "Distribution: $PRETTY_NAME"
else
    info "Distribution: Unknown"
fi

info "Kernel: $(uname -r)"
info "Uptime: $(uptime -p)"

# ── GPU Detection ─────────────────────────────────────────────────────────────

header "GPU Hardware"

gpu_list=$(lspci 2>/dev/null | grep -iE "vga|3d|display" || true)

if [ -z "$gpu_list" ]; then
    info "No GPU detected via lspci"
else
    has_nvidia=false
    has_intel=false
    has_amd=false

    while IFS= read -r line; do
        info "Found: $line"
        if echo "$line" | grep -qi nvidia; then has_nvidia=true; fi
        if echo "$line" | grep -qi intel; then has_intel=true; fi
        if echo "$line" | grep -qi amd; then has_amd=true; fi
    done <<< "$gpu_list"

    if $has_nvidia; then
        risk "NVIDIA GPU detected — this hardware is affected by idle freeze bugs"
    fi

    if $has_nvidia && ($has_intel || $has_amd); then
        risk "Hybrid GPU setup (NVIDIA + integrated) — highest risk configuration"
    fi
fi

# ── NVIDIA Driver ─────────────────────────────────────────────────────────────

header "NVIDIA Driver"

if command -v nvidia-smi &>/dev/null; then
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    info "Driver version: $driver_version"
    info "GPU: $gpu_name"

    if lsmod | grep -q nouveau; then
        info "Using: nouveau (open-source) driver"
        ok "nouveau is generally not affected by this issue"
    else
        info "Using: proprietary NVIDIA driver"
        warn "Proprietary NVIDIA driver is known to have suspend/resume issues"
    fi
else
    if lsmod | grep -q nouveau; then
        info "Using: nouveau (open-source) driver"
        ok "nouveau is generally not affected by this issue"
    elif $has_nvidia 2>/dev/null; then
        warn "NVIDIA GPU detected but no driver loaded"
    else
        ok "No NVIDIA driver in use"
    fi
fi

# ── NVIDIA Persistence Mode ──────────────────────────────────────────────────

if command -v nvidia-smi &>/dev/null; then
    persistence=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    if [ "$persistence" = "Enabled" ]; then
        ok "NVIDIA persistence mode: enabled"
    else
        warn "NVIDIA persistence mode: disabled (can contribute to resume failures)"
    fi
fi

# ── Display Manager ──────────────────────────────────────────────────────────

header "Display Manager"

dm="unknown"
if systemctl is-active --quiet gdm 2>/dev/null || systemctl is-active --quiet gdm3 2>/dev/null; then
    dm="gdm"
    info "Display manager: GDM (GNOME Display Manager)"
elif systemctl is-active --quiet sddm 2>/dev/null; then
    dm="sddm"
    info "Display manager: SDDM (KDE)"
elif systemctl is-active --quiet lightdm 2>/dev/null; then
    dm="lightdm"
    info "Display manager: LightDM"
else
    info "Display manager: could not detect"
fi

# ── Session Type ──────────────────────────────────────────────────────────────

header "Display Session"

# Try to detect session type from running processes
session_type="unknown"
for pid in $(pgrep gnome-shell 2>/dev/null || true) $(pgrep plasmashell 2>/dev/null || true); do
    st=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep ^XDG_SESSION_TYPE= | cut -d= -f2 || true)
    if [ -n "$st" ]; then
        session_type="$st"
        break
    fi
done

if [ "$session_type" = "x11" ]; then
    info "Session type: X11"
    warn "X11 + NVIDIA is the most common configuration for idle freezes"
elif [ "$session_type" = "wayland" ]; then
    info "Session type: Wayland"
    info "Wayland can also be affected, though failure modes differ"
else
    info "Session type: could not detect (are you running this from a TTY?)"
fi

# Detect desktop environment
de="unknown"
for pid in $(pgrep gnome-shell 2>/dev/null || true) $(pgrep plasmashell 2>/dev/null || true) $(pgrep cinnamon 2>/dev/null || true); do
    d=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep ^XDG_CURRENT_DESKTOP= | cut -d= -f2 || true)
    if [ -n "$d" ]; then
        de="$d"
        break
    fi
done
info "Desktop environment: $de"

# ── Power Management Settings ────────────────────────────────────────────────

header "Power Management Settings (THE IMPORTANT PART)"

echo
info "Checking settings that cause idle freezes..."
echo

# GNOME settings
if command -v gsettings &>/dev/null; then

    # Sleep on AC
    val=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 2>/dev/null || echo "N/A")
    if [ "$val" = "'nothing'" ]; then
        ok "Sleep on AC power: disabled"
    elif [ "$val" != "N/A" ]; then
        risk "Sleep on AC power: $val — THIS WILL CAUSE FREEZES"
    fi

    # Sleep on battery
    val=$(gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 2>/dev/null || echo "N/A")
    if [ "$val" = "'nothing'" ]; then
        ok "Sleep on battery: disabled"
    elif [ "$val" != "N/A" ]; then
        risk "Sleep on battery: $val — THIS WILL CAUSE FREEZES"
    fi

    # Idle delay
    val=$(gsettings get org.gnome.desktop.session idle-delay 2>/dev/null || echo "N/A")
    if [ "$val" = "uint32 0" ]; then
        ok "Screen idle timeout: disabled"
    elif [ "$val" != "N/A" ]; then
        delay=$(echo "$val" | grep -o '[0-9]*')
        risk "Screen idle timeout: ${delay}s — screen will blank after ${delay} seconds of inactivity"
    fi

    # Screensaver
    val=$(gsettings get org.gnome.desktop.screensaver idle-activation-enabled 2>/dev/null || echo "N/A")
    if [ "$val" = "false" ]; then
        ok "Screensaver auto-activation: disabled"
    elif [ "$val" != "N/A" ]; then
        risk "Screensaver auto-activation: enabled — CAN TRIGGER DISPLAY FREEZE"
    fi

    # Lid close
    val=$(gsettings get org.gnome.settings-daemon.plugins.power lid-close-ac-action 2>/dev/null || echo "N/A")
    if [ "$val" = "'nothing'" ]; then
        ok "Lid close on AC: disabled"
    elif [ "$val" != "N/A" ]; then
        warn "Lid close on AC: $val"
    fi

    val=$(gsettings get org.gnome.settings-daemon.plugins.power lid-close-battery-action 2>/dev/null || echo "N/A")
    if [ "$val" = "'nothing'" ]; then
        ok "Lid close on battery: disabled"
    elif [ "$val" != "N/A" ]; then
        warn "Lid close on battery: $val"
    fi
fi

# KDE settings
if [ -f "$HOME/.config/powermanagementprofilesrc" ]; then
    info "KDE power management config found"
    if grep -q "idleTime=" "$HOME/.config/powermanagementprofilesrc" 2>/dev/null; then
        warn "KDE idle timeout is configured — check powermanagementprofilesrc"
    fi
fi

# ── System-Level Settings ────────────────────────────────────────────────────

header "System-Level Protection"

# Check dconf system overrides
if [ -f /etc/dconf/db/local.d/00-freeze-guard ] || [ -f /etc/dconf/db/local.d/00-no-suspend ]; then
    ok "System-level dconf override found (survives package updates)"
else
    warn "No system-level dconf override — settings WILL be reverted by package updates"
fi

# Check systemd targets
echo
for target in sleep suspend hibernate hybrid-sleep; do
    state="$(systemctl is-enabled ${target}.target 2>/dev/null)" || true
    state="$(echo "$state" | head -1 | tr -d '[:space:]')"
    [ -z "$state" ] && state="unknown"
    if [ "$state" = "masked" ]; then
        ok "systemd ${target}.target: masked"
    elif [ "$state" = "static" ]; then
        warn "systemd ${target}.target: static (not masked)"
    else
        risk "systemd ${target}.target: $state — system CAN suspend"
    fi
done

# Check logind.conf (main file and drop-ins)
echo
lid_switch="not set"
# Check drop-in first (takes precedence)
if [ -f /etc/systemd/logind.conf.d/freeze-guard.conf ]; then
    lid_switch=$(grep -E "^HandleLidSwitch=" /etc/systemd/logind.conf.d/freeze-guard.conf 2>/dev/null | cut -d= -f2 || echo "not set")
fi
# Fall back to main config
if [ "$lid_switch" = "not set" ] && [ -f /etc/systemd/logind.conf ]; then
    lid_switch=$(grep -E "^HandleLidSwitch=" /etc/systemd/logind.conf 2>/dev/null | cut -d= -f2 || echo "not set")
fi

if [ "$lid_switch" = "ignore" ]; then
    ok "logind HandleLidSwitch: ignore"
elif [ "$lid_switch" = "not set" ]; then
    warn "logind HandleLidSwitch: not set (defaults to suspend)"
else
    risk "logind HandleLidSwitch: $lid_switch"
fi

# ── Journal Analysis ─────────────────────────────────────────────────────────

header "Recent Freeze Evidence (Journal Analysis)"

echo
info "Scanning system logs for signs of display freezes..."
echo

# Look for NVIDIA display config failures (using --grep for speed)
nvidia_fails=$(journalctl --no-pager -b -1 --grep="NVIDIA.*Failed to set the display configuration" 2>/dev/null | wc -l || true)
nvidia_fails=${nvidia_fails:-0}
if [ "$nvidia_fails" -gt 0 ] 2>/dev/null; then
    risk "Found $nvidia_fails NVIDIA display configuration failure(s) in previous boot"
fi

# Look for Xorg I/O errors
xorg_errors=$(journalctl --no-pager -b -1 --grep="xf86CloseConsole.*Input/output error" 2>/dev/null | wc -l || true)
xorg_errors=${xorg_errors:-0}
if [ "$xorg_errors" -gt 0 ] 2>/dev/null; then
    risk "Found $xorg_errors Xorg I/O error(s) in previous boot — display was locked up"
fi

# Look for GDM/GNOME Shell crashes
gnome_crashes=$(journalctl --no-pager -b -1 --grep="gnome-shell.*(crash|SIGSEGV|SIGABRT)" 2>/dev/null | wc -l || true)
gnome_crashes=${gnome_crashes:-0}
if [ "$gnome_crashes" -gt 0 ] 2>/dev/null; then
    risk "Found $gnome_crashes GNOME Shell crash(es) in previous boot"
fi

# Look for lid events near reboots
lid_events=$(journalctl --no-pager -b -1 --grep="Lid (opened|closed)" 2>/dev/null | wc -l || true)
lid_events=${lid_events:-0}
if [ "$lid_events" -gt 0 ] 2>/dev/null; then
    info "Found $lid_events lid open/close event(s) in previous boot"
    warn "Lid events near system freezes suggest suspend/resume as the trigger"
fi

# Count reboots in journal
boot_count=$(journalctl --list-boots --no-pager 2>/dev/null | wc -l || echo "unknown")
info "Total boots recorded in journal: $boot_count"

# Check last 3 boots for NVIDIA failures (using --grep for speed)
multi_boot_fails=0
for boot_id in $(journalctl --list-boots --no-pager 2>/dev/null | tail -3 | awk '{print $2}'); do
    fails=$(journalctl --no-pager -b "$boot_id" --grep="NVIDIA.*Failed to set the display configuration" 2>/dev/null | wc -l || true)
    fails=${fails:-0}
    multi_boot_fails=$((multi_boot_fails + fails))
done
if [ "$multi_boot_fails" -gt 2 ]; then
    risk "NVIDIA display failures found across multiple recent boots — this is a recurring issue"
fi

# ── Freeze Type Guide ────────────────────────────────────────────────────────

header "Freeze Types (What You See)"

echo
echo -e "  ${BOLD}Type 1: Cursor moves, everything else frozen${NC}"
echo    "    → GNOME Shell (compositor) has crashed or hung"
echo    "    → The GPU is partially functional"
echo    "    → Recovery: Ctrl+Alt+F4, then: sudo systemctl restart gdm"
echo
echo -e "  ${BOLD}Type 2: Cursor is also frozen, screen completely stuck${NC}"
echo    "    → The X server or GPU driver is completely locked up"
echo    "    → Deeper failure, usually from suspend/resume"
echo    "    → Recovery: Ctrl+Alt+F4 (may or may not work), then: sudo systemctl restart gdm"
echo    "    → If TTY doesn't work: SSH in from another machine, or hold power button"
echo

# ── Summary ──────────────────────────────────────────────────────────────────

header "Summary"

echo
if [ "$risk_count" -gt 0 ]; then
    echo -e "${RED}${BOLD}Found $risk_count critical risk(s) and $warn_count warning(s).${NC}"
    echo
    echo -e "Your system is ${RED}${BOLD}likely to freeze${NC} when left idle."
    echo -e "Run ${BOLD}sudo ./fix.sh${NC} to apply persistent fixes."
elif [ "$warn_count" -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}Found $warn_count warning(s), no critical risks.${NC}"
    echo
    echo -e "Your system is ${YELLOW}partially protected${NC}. Review warnings above."
else
    echo -e "${GREEN}${BOLD}No risks detected. Your system appears to be protected.${NC}"
fi
echo
