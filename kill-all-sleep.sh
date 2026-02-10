#!/bin/bash
# NUCLEAR OPTION: Kill ALL sleep/suspend mechanisms

set -e

echo "=== KILLING ALL SLEEP MECHANISMS ==="

# 1. Add kernel parameters to disable sleep states
echo "[1/6] Adding kernel parameters..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash.*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash mem_sleep_default=s2idle acpi.sleep=0"/' /etc/default/grub
update-grub

# 2. Create systemd sleep override
echo "[2/6] Creating systemd sleep override..."
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/nosleep.conf << 'EOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
EOF

# 3. Mask ALL sleep-related targets
echo "[3/6] Masking all sleep targets..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target 2>/dev/null || true

# 4. Disable DPMS and screen blanking
echo "[4/6] Disabling DPMS..."
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

# 5. Make kernel sleep states unavailable at boot
echo "[5/6] Blocking /sys/power/state access..."
cat > /etc/rc.local << 'EOF'
#!/bin/bash
chmod 000 /sys/power/state 2>/dev/null || true
exit 0
EOF
chmod +x /etc/rc.local

# Enable rc-local service if it exists
systemctl enable rc-local 2>/dev/null || true

# 6. Also block it right now
echo "[6/6] Blocking sleep state immediately..."
chmod 000 /sys/power/state 2>/dev/null || true

echo ""
echo "=== ALL SLEEP MECHANISMS KILLED ==="
echo "Reboot required for kernel parameters to take effect."
echo ""
read -p "Reboot now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
