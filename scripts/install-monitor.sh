#!/bin/bash
# ============================================================================
# Linux Idle Freeze Guard - Monitor Installer
# ============================================================================
# Installs a systemd timer that checks after every package upgrade whether
# power management settings have been reverted to dangerous defaults.
#
# If a regression is detected, it automatically re-applies the fix and
# logs a warning.
#
# Run: sudo ./install-monitor.sh
# Requires root.
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[ OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║   Linux Idle Freeze Guard - Monitor Installer    ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Install the check script ────────────────────────────────────────────────

install_dir="/usr/local/lib/freeze-guard"
mkdir -p "$install_dir"

cat > "${install_dir}/check-settings.sh" << 'CHECKER'
#!/bin/bash
# Linux Idle Freeze Guard - Settings Regression Checker
# Called by systemd timer or apt/dnf/pacman hooks

LOG_TAG="freeze-guard"
FIXES_APPLIED=0

log_warn() {
    logger -t "$LOG_TAG" -p user.warning "$1"
    echo "WARNING: $1"
}

log_info() {
    logger -t "$LOG_TAG" -p user.info "$1"
}

log_info "Checking for power management settings regressions..."

# ── Check systemd targets ────────────────────────────────────────────────────

for target in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
    state=$(systemctl is-enabled ${target}.target 2>/dev/null || echo "not-found")
    if [ "$state" != "masked" ] && [ "$state" != "not-found" ]; then
        log_warn "systemd ${target}.target is no longer masked (state: $state). Re-masking."
        systemctl mask ${target}.target 2>/dev/null
        FIXES_APPLIED=$((FIXES_APPLIED + 1))
    fi
done

# ── Check dconf override ────────────────────────────────────────────────────

if [ ! -f /etc/dconf/db/local.d/00-freeze-guard ]; then
    log_warn "dconf override file is missing! Re-creating."

    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/00-freeze-guard << 'DCONF'
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

    dconf update 2>/dev/null
    FIXES_APPLIED=$((FIXES_APPLIED + 1))
fi

# ── Check dconf locks ───────────────────────────────────────────────────────

if [ ! -f /etc/dconf/db/local.d/locks/freeze-guard ]; then
    log_warn "dconf locks are missing! Re-creating."

    mkdir -p /etc/dconf/db/local.d/locks
    cat > /etc/dconf/db/local.d/locks/freeze-guard << 'LOCKS'
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/idle-activation-enabled
LOCKS

    dconf update 2>/dev/null
    FIXES_APPLIED=$((FIXES_APPLIED + 1))
fi

# ── Check logind drop-in ────────────────────────────────────────────────────

if [ ! -f /etc/systemd/logind.conf.d/freeze-guard.conf ]; then
    log_warn "logind drop-in is missing! Re-creating."

    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/freeze-guard.conf << 'LOGIND'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
IdleActionSec=0
LOGIND

    systemctl restart systemd-logind 2>/dev/null || true
    FIXES_APPLIED=$((FIXES_APPLIED + 1))
fi

# ── Check Xorg DPMS override ────────────────────────────────────────────────

if [ -d /etc/X11/xorg.conf.d ] && [ ! -f /etc/X11/xorg.conf.d/10-freeze-guard-dpms.conf ]; then
    log_warn "Xorg DPMS override is missing! Re-creating."

    cat > /etc/X11/xorg.conf.d/10-freeze-guard-dpms.conf << 'XORG'
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

    FIXES_APPLIED=$((FIXES_APPLIED + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────

if [ "$FIXES_APPLIED" -gt 0 ]; then
    log_warn "Re-applied $FIXES_APPLIED fix(es) that were reverted (likely by a package update)."

    # Try to send desktop notification if possible
    for user_home in /home/*; do
        user=$(basename "$user_home")
        uid=$(id -u "$user" 2>/dev/null || continue)
        if [ -S "/run/user/$uid/bus" ]; then
            sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                notify-send -u critical "Freeze Guard" \
                "A package update reverted your power settings. $FIXES_APPLIED fix(es) have been automatically re-applied." \
                2>/dev/null || true
            break
        fi
    done
else
    log_info "All settings are intact. No regressions detected."
fi

exit 0
CHECKER

chmod +x "${install_dir}/check-settings.sh"
ok "Installed check script: ${install_dir}/check-settings.sh"

# ── Install systemd service ─────────────────────────────────────────────────

cat > /etc/systemd/system/freeze-guard-check.service << SERVICE
[Unit]
Description=Linux Idle Freeze Guard - Check for settings regressions
After=network.target

[Service]
Type=oneshot
ExecStart=${install_dir}/check-settings.sh
SERVICE

ok "Installed systemd service: freeze-guard-check.service"

# ── Install systemd timer ───────────────────────────────────────────────────

cat > /etc/systemd/system/freeze-guard-check.timer << TIMER
[Unit]
Description=Linux Idle Freeze Guard - Periodic settings check

[Timer]
# Run once at boot
OnBootSec=2min
# Run every 6 hours as a safety net
OnUnitActiveSec=6h
# Run persistence check
Persistent=true

[Install]
WantedBy=timers.target
TIMER

ok "Installed systemd timer: freeze-guard-check.timer"

# ── Install apt hook (Debian/Ubuntu) ─────────────────────────────────────────

if command -v apt &>/dev/null; then
    mkdir -p /etc/apt/apt.conf.d

    cat > /etc/apt/apt.conf.d/99-freeze-guard << 'APT'
// Linux Idle Freeze Guard
// Check for power management regressions after every package upgrade
DPkg::Post-Invoke { "/usr/local/lib/freeze-guard/check-settings.sh >/dev/null 2>&1 || true"; };
APT

    ok "Installed apt hook: /etc/apt/apt.conf.d/99-freeze-guard"
fi

# ── Install dnf hook (Fedora/RHEL) ──────────────────────────────────────────

if command -v dnf &>/dev/null && [ -d /etc/dnf/plugins ]; then
    info "For Fedora/RHEL: add a dnf post-transaction hook manually if needed"
    info "See: https://dnf-plugins-core.readthedocs.io/en/latest/post-transaction-actions.html"
fi

# ── Install pacman hook (Arch) ──────────────────────────────────────────────

if command -v pacman &>/dev/null; then
    mkdir -p /etc/pacman.d/hooks

    cat > /etc/pacman.d/hooks/freeze-guard.hook << 'PACMAN'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Checking freeze-guard settings...
When = PostTransaction
Exec = /usr/local/lib/freeze-guard/check-settings.sh
PACMAN

    ok "Installed pacman hook: /etc/pacman.d/hooks/freeze-guard.hook"
fi

# ── Enable and start ────────────────────────────────────────────────────────

systemctl daemon-reload
systemctl enable freeze-guard-check.timer
systemctl start freeze-guard-check.timer

ok "Timer enabled and started"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║${NC}  ${GREEN}Monitor installed successfully.${NC}"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  It will check for settings regressions:"
echo -e "${BOLD}║${NC}    • After every package upgrade (apt/pacman hook)"
echo -e "${BOLD}║${NC}    • Every 6 hours (systemd timer)"
echo -e "${BOLD}║${NC}    • 2 minutes after boot"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  If a regression is found, it will:"
echo -e "${BOLD}║${NC}    • Automatically re-apply the fix"
echo -e "${BOLD}║${NC}    • Send a desktop notification"
echo -e "${BOLD}║${NC}    • Log to syslog (tag: freeze-guard)"
echo -e "${BOLD}║${NC}"
echo -e "${BOLD}║${NC}  Check status: ${BOLD}systemctl status freeze-guard-check.timer${NC}"
echo -e "${BOLD}║${NC}  View logs:    ${BOLD}journalctl -t freeze-guard${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo
