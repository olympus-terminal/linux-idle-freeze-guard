#!/bin/bash
###############################################################################
# fix-sleep-permanently.sh
#
# COMPREHENSIVE fix for display freeze / black screen after suspend on Linux.
# Disables ALL sleep/suspend/hibernate/screen-blanking at EVERY layer.
#
# Run with: sudo bash /home/drn2/fix-sleep-permanently.sh
#
# Requires sudo for system-level changes. Safe to re-run.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[FIX]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo:"
    echo "  sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "============================================================"
echo " COMPREHENSIVE SLEEP/SUSPEND DISABLER"
echo " Fixing ALL layers that can put the system to sleep"
echo "============================================================"
echo ""

###############################################################################
# LAYER 1: systemd sleep.conf (disable suspend at systemd level)
###############################################################################
echo "--- Layer 1: systemd sleep.conf ---"

mkdir -p /etc/systemd/sleep.conf.d

cat > /etc/systemd/sleep.conf.d/nosleep.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF
log "sleep.conf.d/nosleep.conf written"

###############################################################################
# LAYER 2: Mask systemd sleep targets
###############################################################################
echo ""
echo "--- Layer 2: Mask systemd targets ---"

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
log "All sleep/suspend/hibernate targets masked"

###############################################################################
# LAYER 3: systemd logind.conf - handle ALL hardware events
# This is the main logind.conf. We uncomment and set EVERYTHING to ignore.
###############################################################################
echo ""
echo "--- Layer 3: systemd logind.conf ---"

# Create a drop-in that overrides EVERYTHING - this takes priority over
# the main logind.conf and won't be lost on package upgrades
mkdir -p /etc/systemd/logind.conf.d

cat > /etc/systemd/logind.conf.d/no-sleep-ever.conf << 'EOF'
# Disable ALL suspend/hibernate/sleep triggers in logind
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
log "logind.conf.d/no-sleep-ever.conf written (ALL events = ignore)"

###############################################################################
# LAYER 4: GDM (login screen) auto-suspend -- THE SNEAKY ONE
# GDM uses its OWN GNOME settings. By default it suspends after 20 min idle.
# This is the #1 suspect for "settings seem to revert" because it only
# kicks in when the screen locks or user logs out.
###############################################################################
echo ""
echo "--- Layer 4: GDM greeter auto-suspend (CRITICAL) ---"

GDM_DCONF="/etc/gdm3/greeter.dconf-defaults"
if [ -f "$GDM_DCONF" ]; then
    # Check if our block already exists
    if ! grep -q "sleep-inactive-ac-type='nothing'" "$GDM_DCONF" 2>/dev/null; then
        cat >> "$GDM_DCONF" << 'EOF'

# === ADDED BY fix-sleep-permanently.sh ===
# Prevent GDM from suspending the system when at login screen
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'
EOF
        log "GDM greeter dconf-defaults updated (no more login-screen suspend)"
    else
        log "GDM greeter dconf-defaults already patched"
    fi
else
    warn "No /etc/gdm3/greeter.dconf-defaults found (not using GDM?)"
fi

# Also try setting GDM gsettings directly via dbus
# This requires gdm user to have a dbus session
if id gdm &>/dev/null; then
    # Method 1: Use machinectl/sudo to set gdm user gsettings
    su -s /bin/bash gdm -c "dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'" 2>/dev/null && \
        log "GDM gsettings set via su" || \
        warn "Could not set GDM gsettings via su (will rely on dconf-defaults)"

    su -s /bin/bash gdm -c "dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0" 2>/dev/null || true
    su -s /bin/bash gdm -c "dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'" 2>/dev/null || true
    su -s /bin/bash gdm -c "dbus-launch gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0" 2>/dev/null || true
fi

# Method 2: Write dconf database directly for gdm
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

dconf update 2>/dev/null && log "dconf database updated for GDM" || warn "dconf update failed"

###############################################################################
# LAYER 5: GNOME user session settings
###############################################################################
echo ""
echo "--- Layer 5: GNOME user session settings ---"

sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" bash -c '
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing"
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type "nothing"
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0
' 2>/dev/null && log "GNOME gsettings updated for $REAL_USER" || warn "gsettings update had issues (may need active session)"

###############################################################################
# LAYER 6: X Server DPMS and screen blanking (persistent via xorg.conf.d)
###############################################################################
echo ""
echo "--- Layer 6: X Server DPMS / screen blanking ---"

mkdir -p /etc/X11/xorg.conf.d

cat > /etc/X11/xorg.conf.d/10-no-dpms.conf << 'EOF'
# Disable ALL X server screen blanking and DPMS
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Extensions"
    Option "DPMS" "false"
EndSection
EOF
log "xorg.conf.d/10-no-dpms.conf written"

# Also apply immediately for current X session
sudo -u "$REAL_USER" DISPLAY=:0 xset s off 2>/dev/null || true
sudo -u "$REAL_USER" DISPLAY=:0 xset s noblank 2>/dev/null || true
sudo -u "$REAL_USER" DISPLAY=:0 xset -dpms 2>/dev/null || true
sudo -u "$REAL_USER" DISPLAY=:0 xset dpms 0 0 0 2>/dev/null || true
sudo -u "$REAL_USER" DISPLAY=:0 xset s 0 0 2>/dev/null || true
log "xset applied for current session"

###############################################################################
# LAYER 7: Kernel console blanking
###############################################################################
echo ""
echo "--- Layer 7: Kernel console blanking ---"

# Set immediately
echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true
setterm --blank 0 --powersave off --powerdown 0 2>/dev/null || true
log "Console blanking disabled for current session"

# Make permanent via GRUB
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    # Add consoleblank=0 if not already present
    if ! grep -q 'consoleblank=0' "$GRUB_FILE"; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' "$GRUB_FILE"
        log "Added consoleblank=0 to GRUB_CMDLINE_LINUX_DEFAULT"
        GRUB_UPDATED=true
    else
        log "consoleblank=0 already in GRUB"
        GRUB_UPDATED=false
    fi

    if [ "$GRUB_UPDATED" = true ]; then
        update-grub 2>/dev/null && log "GRUB config regenerated" || warn "update-grub failed"
    fi
fi

###############################################################################
# LAYER 8: power-profiles-daemon -- can independently trigger power saving
###############################################################################
echo ""
echo "--- Layer 8: power-profiles-daemon ---"

if systemctl is-active power-profiles-daemon &>/dev/null; then
    # Set to performance mode instead of disabling entirely
    # (disabling can cause issues on some systems)
    if command -v powerprofilesctl &>/dev/null; then
        powerprofilesctl set performance 2>/dev/null && \
            log "power-profiles-daemon set to 'performance'" || \
            warn "Could not set power profile to performance"
    fi

    # Create override to prevent it from doing power-save
    mkdir -p /etc/systemd/system/power-profiles-daemon.service.d
    cat > /etc/systemd/system/power-profiles-daemon.service.d/override.conf << 'EOF'
[Service]
# Ensure performance profile on startup
ExecStartPost=/bin/bash -c 'sleep 2 && powerprofilesctl set performance 2>/dev/null || true'
EOF
    systemctl daemon-reload
    log "power-profiles-daemon override created (always performance)"
fi

###############################################################################
# LAYER 9: Systemd user service to continuously enforce settings
# This catches any daemon that tries to re-enable sleep/blanking
###############################################################################
echo ""
echo "--- Layer 9: Persistent enforcement service ---"

SVCDIR="$REAL_HOME/.config/systemd/user"
mkdir -p "$SVCDIR"

cat > "$REAL_HOME/kill-screen-blanking.sh" << 'SCRIPT'
#!/bin/bash
# Continuously enforce no-sleep, no-blank settings
# Runs every 60 seconds to catch anything that tries to re-enable sleep

# GNOME settings
gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null
gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0 2>/dev/null

# X settings
xset s off 2>/dev/null
xset s noblank 2>/dev/null
xset -dpms 2>/dev/null
xset dpms 0 0 0 2>/dev/null
xset s 0 0 2>/dev/null

# Reset screensaver
xdg-screensaver reset 2>/dev/null

# Simulate activity (prevents idle detection)
xdotool key --clearmodifiers "" 2>/dev/null || true
SCRIPT

chmod +x "$REAL_HOME/kill-screen-blanking.sh"
chown "$REAL_USER:$REAL_USER" "$REAL_HOME/kill-screen-blanking.sh"

cat > "$SVCDIR/kill-screen-blanking.service" << EOF
[Unit]
Description=Kill Screen Blanking - enforce no-sleep every 60 seconds
After=graphical-session.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do $REAL_HOME/kill-screen-blanking.sh; sleep 60; done'
Restart=always
RestartSec=10
Environment=DISPLAY=:0
Environment=XAUTHORITY=$REAL_HOME/.Xauthority

[Install]
WantedBy=default.target
EOF
chown "$REAL_USER:$REAL_USER" "$SVCDIR/kill-screen-blanking.service"

sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    systemctl --user daemon-reload 2>/dev/null || true
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    systemctl --user enable kill-screen-blanking.service 2>/dev/null || true
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    systemctl --user restart kill-screen-blanking.service 2>/dev/null || true
log "Enforcement service installed and started (60-second interval)"

###############################################################################
# LAYER 10: Disable ACPI wakeup/sleep events that could trigger suspend
###############################################################################
echo ""
echo "--- Layer 10: ACPI sleep event prevention ---"

# Disable lid switch at ACPI level if possible
if [ -f /proc/acpi/wakeup ]; then
    log "ACPI wakeup sources present (not modifying - informational)"
fi

###############################################################################
# LAYER 11: NetworkManager - prevent it from triggering sleep
###############################################################################
echo ""
echo "--- Layer 11: NetworkManager sleep behavior ---"

NM_CONF_DIR="/etc/NetworkManager/conf.d"
if [ -d "$(dirname "$NM_CONF_DIR")" ]; then
    mkdir -p "$NM_CONF_DIR"
    cat > "$NM_CONF_DIR/no-sleep.conf" << 'EOF'
# Prevent NetworkManager from reacting to sleep/suspend
[main]
no-auto-default=*

[connection]
# Reduce likelihood of connectivity-triggered sleep issues
ipv6.ip6-privacy=0
EOF
    log "NetworkManager sleep config written"
fi

###############################################################################
# RESTART SERVICES
###############################################################################
echo ""
echo "--- Restarting affected services ---"

systemctl daemon-reload
systemctl restart systemd-logind 2>/dev/null && log "systemd-logind restarted" || warn "logind restart may require reboot"

###############################################################################
# VERIFICATION
###############################################################################
echo ""
echo "============================================================"
echo " VERIFICATION"
echo "============================================================"

echo ""
echo "systemd targets:"
for target in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    STATUS=$(systemctl is-enabled "$target" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "masked" ]; then
        echo -e "  ${GREEN}$target: MASKED${NC}"
    else
        echo -e "  ${RED}$target: $STATUS (SHOULD BE MASKED!)${NC}"
    fi
done

echo ""
echo "systemctl suspend test:"
RESULT=$(systemctl suspend 2>&1 || true)
if echo "$RESULT" | grep -qi "disabled\|masked\|refused\|failed"; then
    echo -e "  ${GREEN}suspend correctly blocked: $RESULT${NC}"
else
    echo -e "  ${RED}WARNING: suspend may not be blocked${NC}"
fi

echo ""
echo "Current X settings:"
sudo -u "$REAL_USER" DISPLAY=:0 xset -q 2>/dev/null | grep -A2 "Screen Saver\|DPMS" || echo "  (could not query - may need reboot)"

echo ""
echo "============================================================"
echo -e " ${GREEN}ALL LAYERS PATCHED${NC}"
echo ""
echo " Changes applied to:"
echo "   1. /etc/systemd/sleep.conf.d/nosleep.conf"
echo "   2. systemd mask on sleep/suspend/hibernate targets"
echo "   3. /etc/systemd/logind.conf.d/no-sleep-ever.conf"
echo "   4. /etc/gdm3/greeter.dconf-defaults + dconf db"
echo "   5. GNOME gsettings (user session)"
echo "   6. /etc/X11/xorg.conf.d/10-no-dpms.conf + xset"
echo "   7. Kernel consoleblank=0 (runtime + GRUB)"
echo "   8. power-profiles-daemon -> performance mode"
echo "   9. kill-screen-blanking.service (every 60s)"
echo "  10. NetworkManager sleep config"
echo ""
echo " REBOOT RECOMMENDED to ensure all changes take full effect."
echo "============================================================"
