#!/bin/bash
# ============================================================================
# NUCLEAR OPTION: Kill ALL sleep/suspend mechanisms
# ============================================================================
# This is the aggressive, standalone version that disables every possible
# sleep path. Use this if fix.sh isn't enough, or as a one-shot fix.
#
# WARNING: Do NOT run this on a live graphical session without reading the
# notes below. This script does NOT restart systemd-logind (doing so would
# revoke input device access from your running X session).
#
# Run: sudo bash kill-all-sleep.sh
# Reboot recommended after running.
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root (use sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}=== KILLING ALL SLEEP MECHANISMS ===${NC}"
echo

# ── 1. Kernel parameters ────────────────────────────────────────────────────

echo "[1/8] Adding kernel parameters..."
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    if ! grep -q 'consoleblank=0' "$GRUB_FILE"; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' "$GRUB_FILE"
    fi
    if ! grep -q 'mem_sleep_default=s2idle' "$GRUB_FILE"; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 mem_sleep_default=s2idle acpi.sleep=0"/' "$GRUB_FILE"
    fi
    update-grub 2>/dev/null && echo -e "${GREEN}  GRUB updated${NC}" || echo -e "${YELLOW}  update-grub failed${NC}"
fi

# ── 2. Systemd sleep override ───────────────────────────────────────────────

echo "[2/8] Creating systemd sleep override..."
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/nosleep.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF
echo -e "${GREEN}  /etc/systemd/sleep.conf.d/nosleep.conf${NC}"

# ── 3. Mask ALL sleep-related targets ───────────────────────────────────────

echo "[3/8] Masking all sleep targets..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true
echo -e "${GREEN}  All sleep targets masked${NC}"

# ── 4. Logind: ignore ALL hardware events ───────────────────────────────────

echo "[4/8] Configuring logind (all events = ignore)..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-sleep-ever.conf << 'EOF'
# Kill ALL suspend/hibernate/sleep triggers in logind
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
EOF
echo -e "${GREEN}  /etc/systemd/logind.conf.d/no-sleep-ever.conf${NC}"
echo -e "${YELLOW}  NOTE: NOT restarting logind (would kill keyboard/mouse in active X session)${NC}"

# ── 5. GDM greeter power settings ──────────────────────────────────────────

echo "[5/8] Disabling GDM greeter auto-suspend..."
if id gdm &>/dev/null; then
    mkdir -p /etc/dconf/profile
    cat > /etc/dconf/profile/gdm << 'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF

    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/10-no-sleep << 'EOF'
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
EOF
    dconf update 2>/dev/null
    echo -e "${GREEN}  GDM greeter dconf override applied${NC}"

    # Also patch greeter.dconf-defaults
    GDM_DCONF="/etc/gdm3/greeter.dconf-defaults"
    if [ -f "$GDM_DCONF" ] && ! grep -q "sleep-inactive-ac-type='nothing'" "$GDM_DCONF" 2>/dev/null; then
        cat >> "$GDM_DCONF" << 'EOF'

# === ADDED BY kill-all-sleep.sh ===
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'
EOF
        echo -e "${GREEN}  GDM greeter.dconf-defaults patched${NC}"
    fi
else
    echo -e "${YELLOW}  GDM user not found, skipping${NC}"
fi

# ── 6. Disable DPMS and screen blanking ────────────────────────────────────

echo "[6/8] Disabling DPMS..."
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-no-dpms.conf << 'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "Extensions"
    Option "DPMS" "false"
EndSection
EOF
echo -e "${GREEN}  /etc/X11/xorg.conf.d/10-no-dpms.conf${NC}"

# ── 7. Block /sys/power/state ──────────────────────────────────────────────

echo "[7/8] Blocking /sys/power/state access..."
chmod 000 /sys/power/state 2>/dev/null || true

cat > /etc/tmpfiles.d/no-sleep.conf << 'EOF'
# Prevent any process from writing to power state
z /sys/power/state 0000 root root -
EOF
echo -e "${GREEN}  /sys/power/state blocked (current + boot)${NC}"

# ── 8. Kernel console blanking ─────────────────────────────────────────────

echo "[8/8] Disabling console blanking..."
echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
setterm --blank 0 --powersave off --powerdown 0 2>/dev/null || true
echo -e "${GREEN}  Console blanking disabled${NC}"

# ── Summary ────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}=== ALL SLEEP MECHANISMS KILLED ===${NC}"
echo
echo "Changes applied:"
echo "  1. GRUB: consoleblank=0, mem_sleep_default=s2idle, acpi.sleep=0"
echo "  2. systemd: AllowSuspend=no (and all variants)"
echo "  3. systemd: sleep/suspend/hibernate targets masked"
echo "  4. logind: ALL events set to ignore (including HandleLidSwitchExternalPower)"
echo "  5. GDM greeter: auto-suspend disabled"
echo "  6. X11: DPMS disabled"
echo "  7. /sys/power/state: access blocked"
echo "  8. Console blanking: disabled"
echo
echo -e "${YELLOW}Reboot recommended for all changes to take effect.${NC}"
echo
read -p "Reboot now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
