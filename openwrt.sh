#!/bin/bash
set -e  # Stop script immediately if any command fails

# ================= CONFIGURATION =================
VMID=1000
VM_NAME="OpenWrt"
STORAGE="local-lvm"
NET_WAN_BRIDGE="vmbr0"      # WAN (Internet Interface)
NET_LAN_BRIDGE="vmbrlan"    # LAN (Internal Network Interface)
LAN_IP="100.0.0.1"
TIG_SERVER="100.0.0.111"    # Monitoring Server Target IP
IMG_URL="https://downloads.openwrt.org/releases/24.10.4/targets/x86/64/openwrt-24.10.4-x86-64-generic-ext4-combined.img.gz"
# ===============================================

# --- Styling & Logging ---
log_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
log_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- Auto Cleanup Handler ---
cleanup() {
    if [ -d "/mnt/openwrt_tmp_$VMID" ]; then
        umount /mnt/openwrt_tmp_$VMID 2>/dev/null || true
        rmdir /mnt/openwrt_tmp_$VMID 2>/dev/null || true
    fi
    if [ -n "$LOOPDEV" ]; then
        losetup -d "$LOOPDEV" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "========================================================"
echo "    OPENWRT AUTOMATED DEPLOYMENT & PROVISIONING"
echo "========================================================"

# --- 1. Pre-flight Checks ---
log_info "Verifying network bridge configuration..."
ip link show "$NET_WAN_BRIDGE" >/dev/null 2>&1 || log_error "Bridge $NET_WAN_BRIDGE not found on host!"
ip link show "$NET_LAN_BRIDGE" >/dev/null 2>&1 || log_error "Bridge $NET_LAN_BRIDGE not found on host!"

# --- 2. Clean Existing VM ---
if qm status $VMID >/dev/null 2>&1; then
    log_info "Detected existing VM with ID $VMID. Initiating teardown..."
    qm stop $VMID >/dev/null 2>&1 || true
    qm destroy $VMID --purge >/dev/null
    log_success "Previous VM instance destroyed successfully."
fi

# --- 3. Prepare Image ---
log_info "Downloading OpenWrt system image..."
rm -f openwrt-prod.img openwrt-prod.img.gz
wget -q -O openwrt-prod.img.gz "$IMG_URL"
gunzip -f openwrt-prod.img.gz || echo "[WARN] Gzip warning ignored"

log_info "Expanding filesystem to 1GB..."
qemu-img resize -f raw openwrt-prod.img 1G

log_info "Resizing root partition and filesystem..."
LOOPDEV=$(losetup -fP --show openwrt-prod.img)
parted -s "$LOOPDEV" resizepart 2 100%
e2fsck -f -p "${LOOPDEV}p2" >/dev/null 2>&1 || true
resize2fs "${LOOPDEV}p2" >/dev/null

# --- 4. Inject Configuration ---
log_info "Mounting image for configuration injection..."
mkdir -p "/mnt/openwrt_tmp_$VMID"
mount "${LOOPDEV}p2" "/mnt/openwrt_tmp_$VMID"

log_info "Injecting network configuration..."
cat <<EOF > "/mnt/openwrt_tmp_$VMID/etc/config/network"
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'fdcd:5412:3412::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '$LAN_IP'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
EOF

log_info "Injecting auto-installation script for TIG Stack integration..."
# Create a self-destructing setup script for the first boot
cat <<EOF > "/mnt/openwrt_tmp_$VMID/root/setup_tig.sh"
#!/bin/sh
# Log all output to /root/setup.log for debugging purposes
exec >/root/setup.log 2>&1

echo "[1/4] Establishing Internet connection..."
# Wait for internet connectivity (ping Google DNS)
count=0
while ! ping -c 1 8.8.8.8; do
    sleep 5
    count=\$((count+1))
    if [ \$count -ge 12 ]; then echo "Critical: No Internet! Aborting setup."; exit 1; fi
done

echo "[2/4] Installing Collectd Plugins..."
opkg update
opkg install collectd collectd-mod-network collectd-mod-cpu \
collectd-mod-load collectd-mod-memory collectd-mod-interface \
collectd-mod-conntrack collectd-mod-ping collectd-mod-thermal \
collectd-mod-iwinfo

echo "[3/4] Configuring Collectd (Target: $TIG_SERVER)..."
cat <<CONFIG > /etc/collectd.conf
BaseDir "/var/run/collectd"
Include "/etc/collectd/conf.d"
PIDFile "/var/run/collectd.pid"
PluginDir "/usr/lib/collectd"
TypesDB "/usr/share/collectd/types.db"
Interval 30
ReadThreads 5
WriteThreads 5
Hostname "OpenWrt"

# --- OUTPUT TO TIG STACK ---
LoadPlugin network
<Plugin network>
	Server "$TIG_SERVER" "25826"
</Plugin>

# --- SENSORS ---
LoadPlugin cpu
LoadPlugin load
LoadPlugin memory
LoadPlugin conntrack
LoadPlugin thermal
LoadPlugin iwinfo

LoadPlugin interface
<Plugin interface>
	IgnoreSelected true
	Interface "lo"
</Plugin>

LoadPlugin ping
<Plugin ping>
	Host "8.8.8.8"
	Interval 30
</Plugin>
CONFIG

echo "[4/4] Starting Services..."
/etc/init.d/collectd enable
/etc/init.d/collectd restart
echo "SETUP COMPLETE!"
EOF

chmod +x "/mnt/openwrt_tmp_$VMID/root/setup_tig.sh"

log_info "Enabling setup trigger on first boot..."
# Inject execution trigger into rc.local
cat <<EOF > "/mnt/openwrt_tmp_$VMID/etc/rc.local"
# Put your custom commands here that should be executed once
# the system init finished. By default this file does nothing.

if [ ! -f /root/setup_done ]; then
    echo "Running TIG Setup..." > /dev/console
    sh /root/setup_tig.sh &
    touch /root/setup_done
fi

exit 0
EOF

umount "/mnt/openwrt_tmp_$VMID"
losetup -d "$LOOPDEV"
unset LOOPDEV 

# --- 5. Create VM ---
log_info "Provisioning VM ID $VMID ($VM_NAME)..."
qm create $VMID --name "$VM_NAME" --ostype l26 \
    --memory 256 --balloon 0 \
    --cpu host --cores 1 --numa 0 \
    --scsihw virtio-scsi-pci \
    --net0 virtio,bridge=$NET_WAN_BRIDGE \
    --net1 virtio,bridge=$NET_LAN_BRIDGE \
    --serial0 socket --vga serial0

log_info "Importing and attaching storage disk..."
qm importdisk $VMID openwrt-prod.img $STORAGE >/dev/null
qm set $VMID --scsi0 $STORAGE:vm-$VMID-disk-0
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --onboot 1

rm -f openwrt-prod.img

# --- 6. Start ---
log_info "Starting VM instance..."
qm start $VMID

echo ""
echo "========================================================"
echo "   DEPLOYMENT SUCCESSFUL"
echo "========================================================"
echo "   Status: VM is booting."
echo "   Next Steps:"
	echo "     1. OpenWrt will initialize and connect to the Internet."
	echo "     2. Auto-Install script will run (~1-2 mins) to setup Collectd."
	echo "     3. Metrics will begin streaming to $TIG_SERVER."

echo ""
echo "   LAN IP: $LAN_IP"
echo "   Console Access: qm terminal $VMID"
echo "========================================================