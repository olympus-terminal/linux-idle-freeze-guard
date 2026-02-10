#!/bin/bash
# ============================================================================
# Linux Idle Freeze Guard - Recovery Script
# ============================================================================
# Run this from a TTY (Ctrl+Alt+F4) when your display is frozen.
# It will restart your display manager and get you back to a working desktop.
#
# Your background processes, terminal sessions, tmux/screen sessions,
# and anything not running in the GUI will survive.
#
# GUI applications (browsers, editors, etc.) WILL be closed.
# Save your work before walking away if you haven't applied the fix yet!
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo
echo -e "${BOLD}╔══════════════════════════════════════════════════╗"
echo "║     Linux Idle Freeze Guard - Recovery            ║"
echo -e "╚══════════════════════════════════════════════════╝${NC}"
echo

# ── What happened ────────────────────────────────────────────────────────────

echo -e "${BOLD}What happened:${NC}"
echo "  One of two things:"
echo "  1. Your display froze after suspend — the NVIDIA GPU failed to wake up"
echo "  2. Your display is fine but keyboard/mouse are dead — systemd-logind"
echo "     failed to restore input device access after suspend/resume"
echo
echo -e "${BOLD}Good news:${NC}"
echo "  Your system is still running. Background processes, tmux/screen"
echo "  sessions, and services are all fine."
echo
echo -e "${YELLOW}${BOLD}Warning:${NC}"
echo "  Restarting the display manager will close all GUI applications."
echo "  Any unsaved work in graphical apps will be lost."
echo
echo -e "${BLUE}${BOLD}Laptop with lid closed?${NC}"
echo "  If you're using an external monitor with the lid closed, you're"
echo "  seeing this on the laptop's built-in display after opening the lid."
echo "  After recovery, close the lid and your external monitor will resume."
echo

# ── Detect display manager ───────────────────────────────────────────────────

dm=""
dm_service=""

if systemctl is-active --quiet gdm3 2>/dev/null; then
    dm="GDM"
    dm_service="gdm3"
elif systemctl is-active --quiet gdm 2>/dev/null; then
    dm="GDM"
    dm_service="gdm"
elif systemctl is-active --quiet sddm 2>/dev/null; then
    dm="SDDM"
    dm_service="sddm"
elif systemctl is-active --quiet lightdm 2>/dev/null; then
    dm="LightDM"
    dm_service="lightdm"
else
    # Try to find it from systemd
    dm_service=$(systemctl list-units --type=service --state=active 2>/dev/null | grep -oP '(gdm3?|sddm|lightdm)\.service' | head -1 | sed 's/.service//' || true)
    if [ -n "$dm_service" ]; then
        dm="$dm_service"
    fi
fi

if [ -z "$dm_service" ]; then
    echo -e "${RED}Could not detect your display manager.${NC}"
    echo
    echo "Try one of these manually:"
    echo "  sudo systemctl restart gdm"
    echo "  sudo systemctl restart gdm3"
    echo "  sudo systemctl restart sddm"
    echo "  sudo systemctl restart lightdm"
    echo
    exit 1
fi

echo -e "${BLUE}Detected display manager:${NC} $dm ($dm_service)"
echo

# ── Confirm ──────────────────────────────────────────────────────────────────

read -p "Restart $dm now? This will close GUI apps. [y/N] " -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ── Restart ──────────────────────────────────────────────────────────────────

echo
echo -e "${BLUE}Restarting $dm...${NC}"

if sudo systemctl restart "$dm_service"; then
    echo
    echo -e "${GREEN}${BOLD}Display manager restarted successfully.${NC}"
    echo
    echo "Press Ctrl+Alt+F1 or Ctrl+Alt+F2 to switch back to your desktop."
    echo "You will see a login screen."
    echo
    echo -e "${YELLOW}To prevent this from happening again, run:${NC}"
    echo "  sudo ./fix.sh"
    echo
else
    echo
    echo -e "${RED}Failed to restart $dm.${NC}"
    echo
    echo "You may need to reboot:"
    echo "  sudo reboot"
    echo
fi
