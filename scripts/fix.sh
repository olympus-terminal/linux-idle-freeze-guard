#!/bin/bash
# ============================================================================
# Linux Idle Freeze Guard - Fix Script
# ============================================================================
# Disables all idle suspend/sleep/screen blanking at every level of the stack,
# locked at the system level so package updates cannot revert the settings.
#
# Run: sudo ./fix.sh
# Requires root.
# ============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()      { echo -e "${GREEN}[ FIX]${NC} $1"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }
already() { echo -e "${GREEN}[  OK]${NC} $1 (already done)"; }

# ── Root Check ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║        Linux Idle Freeze Guard - Fix             ║"
echo "║                                                  ║"
echo "║  Disabling all idle suspend/sleep/screen blank   ║"
echo "║  with persistent, update-proof settings.         ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Detect Distro ────────────────────────────────────────────────────────────

distro="unknown"
pkg_manager="unknown"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian|linuxmint|pop)
            distro="debian"
            pkg_manager="apt"
            ;;
        fedora|rhel|centos|rocky|alma)
            distro="fedora"
            pkg_manager="dnf"
            ;;
        arch|manjaro|endeavouros)
            distro="arch"
            pkg_manager="pacman"
            ;;
        opensuse*|suse*)
            distro="suse"
            pkg_manager="zypper"
            ;;
    esac
    info "Detected: $PRETTY_NAME (family: $distro)"
else
    info "Could not detect distribution, applying generic fixes"
fi

# ── Detect Desktop Environment ───────────────────────────────────────────────

desktop="unknown"

for pid in $(pgrep gnome-shell 2>/dev/null || true); do
    d=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep ^XDG_CURRENT_DESKTOP= | cut -d= -f2 || true)
    if [ -n "$d" ]; then desktop="gnome"; break; fi
done

if [ "$desktop" = "unknown" ]; then
    for pid in $(pgrep plasmashell 2>/dev/null || true); do
        desktop="kde"
        break
    done
fi

if [ "$desktop" = "unknown" ]; then
    for pid in $(pgrep cinnamon 2>/dev/null || true); do
        desktop="cinnamon"
        break
    done
fi

info "Detected desktop: $desktop"

# ── Detect Display Manager ──────────────────────────────────────────────────

dm="unknown"
if systemctl is-active --quiet gdm3 2>/dev/null || systemctl is-active --quiet gdm 2>/dev/null; then
    dm="gdm"
elif systemctl is-active --quiet sddm 2>/dev/null; then
    dm="sddm"
elif systemctl is-active --quiet lightdm 2>/dev/null; then
    dm="lightdm"
fi

info "Detected display manager: $dm"

changes_made=0

# ── 0. NVIDIA GPU D3cold (ROOT CAUSE FIX) ─────────────────────────────────

echo
echo -e "${BOLD}--- NVIDIA GPU D3cold Power State (Primary Fix) ---${NC}"

if lspci 2>/dev/null | grep -qi nvidia; then
    udev_rule="/etc/udev/rules.d/80-nvidia-pm.rules"
    expected_d3cold='ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{d3cold_allowed}="0"'
    expected_power='ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"'

    if [ -f "$udev_rule" ] && grep -q 'd3cold_allowed' "$udev_rule" && grep -q 'power/control' "$udev_rule"; then
        already "NVIDIA D3cold disabled via udev rule"
    else
        cat > "$udev_rule" << 'UDEV'
# Linux Idle Freeze Guard - Disable NVIDIA GPU deep sleep (D3cold)
# This is the primary fix: prevents the GPU from entering a power state
# it cannot recover from, which is the root cause of display freezes.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{d3cold_allowed}="0"
UDEV

        ok "Created udev rule to disable NVIDIA D3cold: $udev_rule"
        changes_made=$((changes_made + 1))
    fi

    # Apply immediately to current session (without reboot)
    for dev in /sys/bus/pci/devices/*; do
        if [ -f "$dev/vendor" ] && [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x10de" ]; then
            if [ -f "$dev/d3cold_allowed" ]; then
                current=$(cat "$dev/d3cold_allowed" 2>/dev/null || echo "unknown")
                if [ "$current" = "1" ]; then
                    echo 0 > "$dev/d3cold_allowed" 2>/dev/null && \
                        ok "Disabled D3cold on $(basename "$dev") (live)" || \
                        skip "Could not disable D3cold on $(basename "$dev") live (will apply after reboot)"
                else
                    already "D3cold already disabled on $(basename "$dev")"
                fi
            fi
            if [ -f "$dev/power/control" ]; then
                echo "on" > "$dev/power/control" 2>/dev/null || true
            fi
        fi
    done
else
    skip "No NVIDIA GPU detected, skipping D3cold fix"
fi

# ── 1. Systemd Targets ──────────────────────────────────────────────────────

echo
echo -e "${BOLD}--- Systemd Sleep Targets ---${NC}"

for target in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
    state=$(systemctl is-enabled ${target}.target 2>/dev/null || echo "not-found")
    if [ "$state" = "masked" ]; then
        already "systemd ${target}.target: masked"
    elif [ "$state" = "not-found" ]; then
        skip "systemd ${target}.target: not found on this system"
    else
        systemctl mask ${target}.target 2>/dev/null && \
            ok "Masked systemd ${target}.target" && \
            changes_made=$((changes_made + 1)) || \
            skip "Could not mask ${target}.target"
    fi
done

# ── 2. Logind Configuration ─────────────────────────────────────────────────

echo
echo -e "${BOLD}--- Logind Configuration ---${NC}"

logind_conf="/etc/systemd/logind.conf"
logind_drop="/etc/systemd/logind.conf.d/freeze-guard.conf"

if [ -f "$logind_conf" ]; then
    mkdir -p /etc/systemd/logind.conf.d

    cat > "$logind_drop" << 'LOGIND'
# Linux Idle Freeze Guard
# Prevent ALL hardware events and idle actions from triggering suspend
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
HandleHibernateKeyLongPress=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=0
LOGIND

    ok "Created logind drop-in: $logind_drop"
    info "  Includes HandleLidSwitchExternalPower=ignore (defaults to suspend if not set)"
    changes_made=$((changes_made + 1))
fi

# ── 3. GDM Greeter Power Settings ────────────────────────────────────────────

echo
echo -e "${BOLD}--- GDM Greeter Power Settings ---${NC}"

# GDM runs its own GNOME session with INDEPENDENT power settings.
# By default, GDM suspends the system after 20 min idle at the login screen.
# This is a very common source of "settings keep reverting" confusion.
if [ "$dm" = "gdm" ] || systemctl is-active gdm3 &>/dev/null || systemctl is-active gdm &>/dev/null; then

    # Method 1: dconf database override for gdm user
    mkdir -p /etc/dconf/profile
    cat > /etc/dconf/profile/gdm << 'GDMPROFILE'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
GDMPROFILE

    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/10-freeze-guard << 'GDMDCONF'
# Linux Idle Freeze Guard - Prevent GDM greeter from suspending
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=uint32 0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=uint32 0
sleep-inactive-battery-type='nothing'

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
lock-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0
GDMDCONF

    dconf update 2>/dev/null && \
        ok "Created GDM greeter dconf override (login screen will not suspend)" || \
        skip "dconf update failed for GDM"

    # Method 2: Patch greeter.dconf-defaults if it exists
    GDM_DCONF="/etc/gdm3/greeter.dconf-defaults"
    if [ -f "$GDM_DCONF" ]; then
        if ! grep -q "freeze-guard" "$GDM_DCONF" 2>/dev/null; then
            cat >> "$GDM_DCONF" << 'GDMDEFAULTS'

# === ADDED BY linux-idle-freeze-guard ===
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'
GDMDEFAULTS
            ok "Patched GDM greeter.dconf-defaults"
        else
            already "GDM greeter.dconf-defaults already patched"
        fi
    fi

    changes_made=$((changes_made + 1))
else
    skip "GDM not detected, skipping greeter power settings"
fi

# ── 4. GNOME / dconf System Override ─────────────────────────────────────────

echo
echo -e "${BOLD}--- Desktop Environment Settings ---${NC}"

if [ "$desktop" = "gnome" ] || [ "$desktop" = "cinnamon" ] || command -v dconf &>/dev/null; then

    mkdir -p /etc/dconf/db/local.d
    mkdir -p /etc/dconf/profile

    # Write the settings override
    cat > /etc/dconf/db/local.d/00-freeze-guard << 'DCONF'
# Linux Idle Freeze Guard
# Prevent idle suspend, screen blanking, and screensaver activation
# These settings are locked at system level to survive package updates

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
idle-dim=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
lock-enabled=false

[org/gnome/settings-daemon/plugins/power]
lid-close-ac-action='nothing'
lid-close-battery-action='nothing'
DCONF

    ok "Created dconf system override: /etc/dconf/db/local.d/00-freeze-guard"

    # Create locks so users/updates can't override these
    mkdir -p /etc/dconf/db/local.d/locks

    cat > /etc/dconf/db/local.d/locks/freeze-guard << 'LOCKS'
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/idle-activation-enabled
LOCKS

    ok "Created dconf locks (settings cannot be changed by updates or GUI)"

    # Ensure dconf profile exists
    if [ ! -f /etc/dconf/profile/user ] || ! grep -q "system-db:local" /etc/dconf/profile/user 2>/dev/null; then
        cat > /etc/dconf/profile/user << 'PROFILE'
user-db:user
system-db:local
PROFILE
        ok "Created dconf profile: /etc/dconf/profile/user"
    fi

    # Update dconf database
    dconf update 2>/dev/null && \
        ok "Updated dconf database" || \
        skip "dconf update failed (may need relogin)"

    changes_made=$((changes_made + 1))

    # Remove the older fix file if it exists
    if [ -f /etc/dconf/db/local.d/00-no-suspend ]; then
        rm -f /etc/dconf/db/local.d/00-no-suspend
        info "Removed older 00-no-suspend file (superseded by 00-freeze-guard)"
        dconf update 2>/dev/null
    fi
fi

if [ "$desktop" = "kde" ]; then
    # KDE uses different config files
    info "KDE detected — applying KDE-specific power settings"

    kde_power_dir="/etc/xdg"
    mkdir -p "$kde_power_dir"

    cat > "$kde_power_dir/powermanagementprofilesrc" << 'KDE'
# Linux Idle Freeze Guard - KDE power settings

[AC][DPMSControl]
idleTimeout=0
lockBeforeTurnOff=0

[AC][SuspendSession]
idleTime=0
suspendThenHibernate=false
suspendType=0

[Battery][DPMSControl]
idleTimeout=0
lockBeforeTurnOff=0

[Battery][SuspendSession]
idleTime=0
suspendThenHibernate=false
suspendType=0

[LowBattery][DPMSControl]
idleTimeout=0
lockBeforeTurnOff=0

[LowBattery][SuspendSession]
idleTime=0
suspendThenHibernate=false
suspendType=0
KDE

    ok "Created KDE power management override"
    changes_made=$((changes_made + 1))
fi

# ── 5. DPMS (Display Power Management) ──────────────────────────────────────

echo
echo -e "${BOLD}--- DPMS (Display Power Management) ---${NC}"

xorg_conf_dir="/etc/X11/xorg.conf.d"
if [ -d /etc/X11 ]; then
    mkdir -p "$xorg_conf_dir"

    cat > "${xorg_conf_dir}/10-freeze-guard-dpms.conf" << 'XORG'
# Linux Idle Freeze Guard - Disable DPMS
# Prevents the display from being powered off by X11

Section "Extensions"
    Option "DPMS" "false"
EndSection

Section "ServerFlags"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
    Option "BlankTime"   "0"
EndSection
XORG

    ok "Created Xorg DPMS override: ${xorg_conf_dir}/10-freeze-guard-dpms.conf"
    changes_made=$((changes_made + 1))
fi

# ── 6. NVIDIA Persistence ───────────────────────────────────────────────────

echo
echo -e "${BOLD}--- NVIDIA Settings ---${NC}"

if command -v nvidia-smi &>/dev/null; then
    # Unmask and enable persistence daemon if available
    if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
        state=$(systemctl is-enabled nvidia-persistenced.service 2>/dev/null || echo "unknown")
        if [ "$state" = "masked" ]; then
            systemctl unmask nvidia-persistenced.service 2>/dev/null
            systemctl enable nvidia-persistenced.service 2>/dev/null
            systemctl start nvidia-persistenced.service 2>/dev/null && \
                ok "Unmasked and enabled nvidia-persistenced" || \
                skip "Could not start nvidia-persistenced"
            changes_made=$((changes_made + 1))
        elif [ "$state" = "enabled" ]; then
            already "nvidia-persistenced: enabled"
        else
            systemctl enable nvidia-persistenced.service 2>/dev/null
            systemctl start nvidia-persistenced.service 2>/dev/null && \
                ok "Enabled nvidia-persistenced" || \
                skip "Could not start nvidia-persistenced"
            changes_made=$((changes_made + 1))
        fi
    else
        info "nvidia-persistenced service not found (may need to install nvidia-utils)"
    fi
else
    skip "No NVIDIA driver detected, skipping NVIDIA-specific fixes"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
if [ "$changes_made" -gt 0 ]; then
    echo -e "${BOLD}║${NC}  ${GREEN}Applied $changes_made fix(es).${NC}"
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  Settings are locked at the system level."
    echo -e "${BOLD}║${NC}  Package updates ${BOLD}cannot${NC} revert them."
    echo -e "${BOLD}║${NC}"
    echo -e "${BOLD}║${NC}  ${YELLOW}Recommended: log out and back in, or reboot.${NC}"
else
    echo -e "${BOLD}║${NC}  ${GREEN}All fixes were already in place. No changes needed.${NC}"
fi
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Run ${BOLD}./diagnose.sh${NC} to verify."
echo -e "${BOLD}║${NC}  Run ${BOLD}sudo ./install-monitor.sh${NC} to watch for regressions."
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo
