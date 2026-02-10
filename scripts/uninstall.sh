#!/bin/bash
# ============================================================================
# Linux Idle Freeze Guard - Uninstall
# ============================================================================
# Removes all fixes, monitors, and hooks installed by this project.
# After uninstalling, your system will return to default power management
# behavior (which may cause freezes if you have an NVIDIA GPU).
#
# Run: sudo ./uninstall.sh
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[DONE]${NC} $1"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $1 (not found)"; }

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root (use sudo).${NC}"
    exit 1
fi

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Linux Idle Freeze Guard - Uninstall          ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}${BOLD}Warning:${NC} This will re-enable default power management."
echo "If you have an NVIDIA GPU, idle freezes may return."
echo
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo

# ── Remove monitor ──────────────────────────────────────────────────────────

if systemctl is-enabled freeze-guard-check.timer &>/dev/null; then
    systemctl stop freeze-guard-check.timer 2>/dev/null || true
    systemctl disable freeze-guard-check.timer 2>/dev/null || true
    ok "Disabled freeze-guard-check.timer"
else
    skip "freeze-guard-check.timer"
fi

for f in /etc/systemd/system/freeze-guard-check.service /etc/systemd/system/freeze-guard-check.timer; do
    if [ -f "$f" ]; then rm -f "$f" && ok "Removed $f"; else skip "$f"; fi
done

if [ -d /usr/local/lib/freeze-guard ]; then
    rm -rf /usr/local/lib/freeze-guard && ok "Removed /usr/local/lib/freeze-guard/"
else
    skip "/usr/local/lib/freeze-guard/"
fi

# ── Remove hooks ────────────────────────────────────────────────────────────

for f in /etc/apt/apt.conf.d/99-freeze-guard /etc/pacman.d/hooks/freeze-guard.hook; do
    if [ -f "$f" ]; then rm -f "$f" && ok "Removed $f"; else skip "$f"; fi
done

# ── Remove dconf overrides ──────────────────────────────────────────────────

for f in /etc/dconf/db/local.d/00-freeze-guard /etc/dconf/db/local.d/00-no-suspend /etc/dconf/db/local.d/locks/freeze-guard /etc/dconf/db/gdm.d/10-freeze-guard; do
    if [ -f "$f" ]; then rm -f "$f" && ok "Removed $f"; else skip "$f"; fi
done

# Remove freeze-guard patch from GDM greeter defaults
GDM_DCONF="/etc/gdm3/greeter.dconf-defaults"
if [ -f "$GDM_DCONF" ] && grep -q "linux-idle-freeze-guard" "$GDM_DCONF" 2>/dev/null; then
    sed -i '/=== ADDED BY linux-idle-freeze-guard ===/,$ d' "$GDM_DCONF"
    ok "Removed freeze-guard patch from GDM greeter.dconf-defaults"
fi

dconf update 2>/dev/null || true

# ── Remove logind drop-in ───────────────────────────────────────────────────

if [ -f /etc/systemd/logind.conf.d/freeze-guard.conf ]; then
    rm -f /etc/systemd/logind.conf.d/freeze-guard.conf
    ok "Removed logind drop-in"
else
    skip "logind drop-in"
fi

# ── Remove Xorg DPMS override ──────────────────────────────────────────────

if [ -f /etc/X11/xorg.conf.d/10-freeze-guard-dpms.conf ]; then
    rm -f /etc/X11/xorg.conf.d/10-freeze-guard-dpms.conf
    ok "Removed Xorg DPMS override"
else
    skip "Xorg DPMS override"
fi

# ── Remove NVIDIA D3cold udev rule ────────────────────────────────────────

if [ -f /etc/udev/rules.d/80-nvidia-pm.rules ]; then
    rm -f /etc/udev/rules.d/80-nvidia-pm.rules
    ok "Removed NVIDIA D3cold udev rule"
    echo -e "${YELLOW}  Warning: GPU may enter deep sleep again, which can cause freezes.${NC}"
else
    skip "NVIDIA D3cold udev rule"
fi

# ── Note: NOT unmasking systemd targets ─────────────────────────────────────

echo
echo -e "${YELLOW}Note:${NC} Systemd sleep/suspend targets were NOT unmasked."
echo "If you want to re-enable system suspend, run:"
echo "  sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target"
echo

systemctl daemon-reload

echo -e "${GREEN}${BOLD}Uninstall complete.${NC} Log out and back in for changes to take effect."
echo
