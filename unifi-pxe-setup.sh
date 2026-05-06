#!/usr/bin/env bash
shopt -s nullglob
#set -euo pipefail
#set -x
# working oth desktop and server fo rpxe


# ==============================================
# Script Configuration & Variables
# ==============================================
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
DIR_PATH=$(dirname "$SCRIPT_PATH")
LOG_DIR="$DIR_PATH/logs"
STDOUT_LOG="$LOG_DIR/output.log"
mkdir -p "$LOG_DIR"

# ==============================================
# Logging Functions
# ==============================================
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
NC="\e[0m"

log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    [[ -t 2 ]] && COLOR_START="$GREEN" || COLOR_START=""
    [[ -t 2 ]] && COLOR_END="$NC" || COLOR_END=""

    if [[ -t 0 ]]; then
        echo -e "$timestamp [INFO] ${COLOR_START}$*${COLOR_END}"
        echo "$timestamp [INFO] $*" >> "$STDOUT_LOG"
    else
        while IFS= read -r line; do
            echo -e "$timestamp [INFO] ${COLOR_START}$line${COLOR_END}"
            echo "$timestamp [INFO] $line" >> "$STDOUT_LOG"
        done
    fi
}

log_error() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    [[ -t 2 ]] && COLOR_START="$RED" || COLOR_START=""
    [[ -t 2 ]] && COLOR_END="$NC" || COLOR_END=""

    if [[ -t 0 ]]; then
        echo -e "$timestamp [ERROR] ${COLOR_START}$*${COLOR_END}" >&2
        echo "$timestamp [ERROR] $*" >> "$STDOUT_LOG"
    else
        while IFS= read -r line; do
            echo -e "$timestamp [ERROR] ${COLOR_START}$line${COLOR_END}" >&2
            echo "$timestamp [ERROR] $line" >> "$STDOUT_LOG"
        done
    fi
}

logging() {
    local func_name="$1"
    shift
    { "$func_name" "$@"; } 1> >(log_info) 2> >(log_error)
}

# ==============================================
# Admin Privileges
# ==============================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "This script must be run as root. Escalating..."

        local script_path
        script_path=$(readlink -f "${BASH_SOURCE[0]}")

        exec sudo bash "$script_path" "$@"
    fi
}

check_root "$@"

# ==============================================
# Network Variables
# ==============================================
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | sort -u | head -n1)
SERVER_IP=$(ip -o -4 addr show "$INTERFACE" | awk '{print $4}' | cut -d'/' -f1)
NETWORK=$(ifconfig "$INTERFACE" | grep -oP 'netmask \K[0-9a-fA-F:.]+')
ACTIVE_GW=$(ip -4 route show default | sort -k5 -n | awk '{print $3; exit}')
DHCP_START="${SERVER_IP%.*}.80"
DHCP_END="${SERVER_IP%.*}.100"

log_info "Detected interface: $INTERFACE"
log_info "Server IP: $SERVER_IP | Range: $SERVER_RANGE | ACTIVE_GW: $ACTIVE_GW"

# ==============================================
# STEP 1: ISO INPUT and DIRs
# ==============================================
ISO_URLS=(
  "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso"
  "https://releases.ubuntu.com/noble/ubuntu-24.04.4-desktop-amd64.iso"
  "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
  "https://releases.ubuntu.com/26.04/ubuntu-26.04-beta-desktop-amd64.iso"
)

DOWNLOAD_DIR="/var/www/html/iso_images"
WEB_ROOT="/var/www/html/ubuntu"
CONFIG_DIR="/var/www/html/auto-install"
SERVER_CONFIG="${CONFIG_DIR}/server"
DESKTOP_CONFIG="${CONFIG_DIR}/desktop"
TFTP_ROOT="/tftp"


mkdir -p "$DOWNLOAD_DIR" "$WEB_ROOT" "$SERVER_CONFIG" "$DESKTOP_CONFIG"
mkdir -p "$TFTP_ROOT"/{grub,efi/boot/grub,bios/boot/casper,bios/pxelinux.cfg}

PXE_CFG="/tftp/bios/pxelinux.cfg/default"
GRUB_CFG="/tftp/grub/grub.cfg"
DNSMASQ_CONF="/etc/dnsmasq.conf"
EXPORTS_FILE="/etc/exports"

# ==============================================
# STEP 2: ARRAYS extract details for dynamic configuration
# ==============================================
FILENAMES=()
VERSIONS=()
TYPES=()
MOUNT_DIRS=()
ISO_PATHS=()
TFTP_CONTENT_DIR=()
FULL_ISO_CONTENT_DIR=()

#=================================== for quick config changes without interupting service
SKIP_SERVICES=false

for arg in "$@"; do
    case "$arg" in
        --no-restart|--update)
            SKIP_SERVICES=true
            ;;
    esac
done

# ==============================================
# STEP 3: DOWNLOAD (SIMPLIFIED & STABLE)
# ==============================================

get_filename() {
    basename "$1"
}

if ! $SKIP_SERVICES; then
log_info "Downloading ISOs (simple + reliable mode)..."

for url in "${ISO_URLS[@]}"; do
    filename="$(get_filename "$url")"
    file="${DOWNLOAD_DIR}/${filename}"
    base_url="$(echo "$url" | sed 's|/[^/]*$||')"

    release_key=$(echo "$base_url" | sed 's|https\?://||; s|/|_|g')
    sums_file="/var/cache/iso_checksums/SHA256SUMS_${release_key}"

    # --------------------------------------
    # Ensure checksum file exists
    # --------------------------------------
    if [[ ! -f "$sums_file" ]]; then
        log_info "Fetching SHA256SUMS from $base_url"
        wget -O "$sums_file" "${base_url}/SHA256SUMS" || {
            log_error "Failed to fetch SHA256SUMS"
            exit 1
        }
    fi

    # --------------------------------------
    # Skip download if ISO already exists
    # --------------------------------------
    if [[ -f "$file" ]]; then
        log_info "ISO exists, skipping: $filename"
        continue
    fi

    # --------------------------------------
    # Download ISO
    # --------------------------------------
    log_info "Downloading $filename"
    wget -c -O "$file" "$url"

    # --------------------------------------
    # Verify existence in SHA file (light check only)
    # --------------------------------------
    if ! grep -q " $filename$" "$sums_file"; then
        log_warn "Warning: $filename not found in SHA256SUMS (skipping strict validation)"
    fi

    log_info "Done: $filename"
done
else
    log_info "Skipping ISO Image download"
fi
# ==============================================
# STEP 4: STEP 3: Extract ISO filename, version, type, and build mount paths
# ==========================================================================
log_info "Parsing ISO metadata..."

ISO_FILES=()
INVALID_ISOS=()

for f in "$DOWNLOAD_DIR"/*.iso; do
    # nullglob ensures loop is skipped if nothing matches
    [[ -e "$f" ]] || continue

    if [[ ! -s "$f" ]]; then
        log_error "Skipping empty ISO: $f"
        INVALID_ISOS+=("$f")
        continue
    fi

    if ! file "$f" | grep -q "ISO 9660"; then
        log_error "Skipping invalid ISO: $f"
        INVALID_ISOS+=("$f")
        continue
    fi

    ISO_FILES+=("$f")
done

#  Hard fail if nothing usable
if [[ ${#ISO_FILES[@]} -eq 0 ]]; then
    log_error "No valid ISO files found in $DOWNLOAD_DIR — exiting"
    exit 1
fi

if [[ ${#INVALID_ISOS[@]} -gt 0 ]]; then
    log_error "Some ISO files were skipped: ${INVALID_ISOS[*]}"
fi


for i in "${ISO_FILES[@]}"; do
    filename=$(basename "$i")
    FILENAMES+=("$filename")

    version=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<< "$filename")
    VERSIONS+=("$version")

    if [[ "$filename" == *desktop* ]]; then
        type="desktop"
    elif [[ "$filename" == *server* ]]; then
        type="server"
    else
        type="unknown"
    fi
    TYPES+=("$type")

    mount_dir="/mnt/ubuntu/${type}.${version}"
    MOUNT_DIRS+=("$mount_dir")

    iso_path="${DOWNLOAD_DIR}/${filename}"
    ISO_PATHS+=("$iso_path")
done

for i in "${!FILENAMES[@]}"; do
    log_info "ISO: ${FILENAMES[$i]} | ${TYPES[$i]} | ${VERSIONS[$i]}"
done

# ==============================================
# STEP 5: PREPARE DIRECTORIES
# ==============================================
log_info "Preparing directories..."

for i in "${!MOUNT_DIRS[@]}"; do
    if [[ -z "${TYPES[$i]}" || -z "${VERSIONS[$i]}" ]]; then
        log_error "Invalid type/version for ${FILENAMES[$i]} — skipping directory creation"
        continue
    fi
    content_dest="${WEB_ROOT}/${TYPES[$i]}.${VERSIONS[$i]}"
    FULL_ISO_CONTENT_DIR+=("$content_dest")

    mkdir -p "$content_dest" "${MOUNT_DIRS[$i]}"
done
# ==============================================
# STEP 6: MOUNT + COPY
# ==============================================
for i in "${!MOUNT_DIRS[@]}"; do
    log_info "Processing ${FILENAMES[$i]}"

    mount_point="${MOUNT_DIRS[$i]}"

    if mountpoint -q "$mount_point"; then
        log_info "Unmounting existing mount"
        logging sudo umount -l "$mount_point"
    fi

    logging sudo mount -o loop,ro "${ISO_PATHS[$i]}" "$mount_point"

    log_info "Copying ISO contents... "$mount_point/" "${FULL_ISO_CONTENT_DIR[$i]}/""
    rsync -a --delete --ignore-existing --info=progress2,stats "$mount_point/" "${FULL_ISO_CONTENT_DIR[$i]}/"

    logging sudo umount "$mount_point"
done

log_info "All ISOs processed successfully"

# ==============================================
# STEP 7: SERVICES RESET
# ==============================================
if ! $SKIP_SERVICES; then
    log_info "Stopping conflicting services..."
    logging sudo systemctl --quiet stop apache2 nfs-kernel-server dnsmasq nginx
    logging sudo systemctl --quiet disable apache2 nfs-kernel-server dnsmasq nginx
else
    log_info "Skipping service stop/disable (fast mode)"
fi
# ==============================================
# STEP 8: INSTALL PACKAGES
# ==============================================
if ! $SKIP_SERVICES; then
log_info "Installing required packages..."
logging sudo apt-get update -y > /dev/null
logging sudo apt-get --fix-broken install
logging sudo apt-get install -y multitail apache2 dnsmasq nfs-kernel-server wget syslinux grub-efi-amd64-signed shim-signed grub-efi-amd64-bin memtest86+ > /dev/null
else
    log_info "Skipping Installing required packages.. (fast mode)"
fi
# ==============================================
# STEP 9: NFS CONFIG
# ==============================================
if ! $SKIP_SERVICES; then
log_info "Configuring NFS..."
logging sudo cp "$EXPORTS_FILE" "${EXPORTS_FILE}.bak.$(date +%F_%T)"
logging sudo truncate -s 0 "$EXPORTS_FILE"

EXPORT_OPTS="*(ro,sync,no_wdelay,insecure_locks,no_root_squash,insecure,no_subtree_check)"

for distro in "$WEB_ROOT"/*/; do
    [ -d "$distro" ] || continue
    echo "$distro $EXPORT_OPTS" | sudo tee -a "$EXPORTS_FILE" > /dev/null
done

logging sudo exportfs -ra
logging sudo systemctl restart nfs-kernel-server

else
    log_info "Skipping Configuring NFS... (fast mode)"
fi

# ==============================================
# STEP 10: DNSMASQ
# ==============================================
log_info "Configuring dnsmasq..."
logging sudo cp -u $DNSMASQ_CONF "/etc/dnsmasq.conf.bak.$(date +%F_%T)"

sudo cp -u $DNSMASQ_CONF "/etc/dnsmasq.conf.bak.$(date +%F_%T)"

sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
port=0                                              # Disable DNS server
dhcp-range=$DHCP_START,$DHCP_END,12h                  # DHCP range
dhcp-option=3,$ACTIVE_GW                              # Default ACTIVE_GW
dhcp-option=6,8.8.8.8,$ACTIVE_GW,1.1.1.1              # DNS servers
dhcp-option=66,$SERVER_IP                             # (optional but helps strict UEFI firmware)
server=8.8.8.8
enable-tftp
tftp-root=$TFTP_ROOT

# Match UEFI first
dhcp-match=set:uefi,option:client-arch,7
dhcp-match=set:uefi,option:client-arch,9
dhcp-match=set:uefi,option:client-arch,11
dhcp-match=set:uefi,option:client-arch,15

# UEFI boot
dhcp-boot=tag:uefi,efi/boot/bootx64.efi

# Default BIOS fallback
dhcp-boot=bios/pxelinux.0,pxeserver,$SERVER_IP

# PXE stability
dhcp-no-override

# ignore client-id changes
dhcp-authoritative
dhcp-ignore-clid
# Log DHCP requests for debugging
log-dhcp
EOF

if ! $SKIP_SERVICES; then
    logging sudo systemctl restart dnsmasq
else
    log_info "Skipping dnsmasq restart"
fi

# STEP 11: PXE FILES
# ==============================================
if ! $SKIP_SERVICES; then
log_info "Preparing PXE boot files..."

wget -q --show-progress -cO /tmp/syslinux-6.04-pre1.tar.gz \
https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz

tar -xvzf /tmp/syslinux-6.04-pre1.tar.gz -C /tmp 1>/dev/null

sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/elflink/ldlinux/ldlinux.c32 $TFTP_ROOT/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/libutil/libutil.c32 $TFTP_ROOT/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/menu/menu.c32 $TFTP_ROOT/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/menu/vesamenu.c32 $TFTP_ROOT/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/core/pxelinux.0 $TFTP_ROOT/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/core/lpxelinux.0 $TFTP_ROOT/bios/
else
    log_info "Skipping skipping copying pxe boot files"
fi


SHIM_EFI=$(dpkg -L shim-signed | grep '/shimx64\.efi\.dualsigned$' | head -n1)
GRUB_EFI=$(dpkg -L grub-efi-amd64-signed | grep '/grubnetx64\.efi\.signed$' | head -n1)

if [[ -z "$SHIM_EFI" || -z "$GRUB_EFI" ]]; then
    log_error "ERROR: Could not locate shim or GRUB EFI binaries"
    exit 1
fi

logging sudo cp -u "$SHIM_EFI" "$TFTP_ROOT/efi/boot/bootx64.efi"
logging sudo cp -u "$GRUB_EFI" "$TFTP_ROOT/efi/boot/grubx64.efi"

logging sudo chmod a+r "$TFTP_ROOT/efi/boot/bootx64.efi" "$TFTP_ROOT/efi/boot/grubx64.efi"


# Copy kernel + initrd to TFTP (preserve directory structure)
MEMTEST=$(find /boot -name "memtest86+*.bin" | head -n1)
logging sudo cp -u "$MEMTEST" "$TFTP_ROOT/bios/memtest86+.bin"

for distro in "$WEB_ROOT"/*/; do
    [ -d "$distro" ] || continue

    distro=${distro%/}
    distro_name=$(basename "$distro")

    src_casper="$distro/casper"
    dst_casper="$TFTP_ROOT/bios/boot/casper/$distro_name"

    VMLINUX=$(find "$src_casper" -maxdepth 1 -type f -name "vmlinuz*" | head -n1)
    INITRD=$(find "$src_casper" -maxdepth 1 -type f -name "initrd*" | head -n1)

    if [[ -z "$VMLINUX" || -z "$INITRD" ]]; then
        log_error "Skipping $distro_name (casper kernel/initrd not found in $src_casper)"
        continue
    fi

    mkdir -p "$dst_casper"

    logging sudo cp -u "$VMLINUX" "$dst_casper/vmlinuz"
    logging sudo cp -u "$INITRD" "$dst_casper/initrd"
done

# ==============================================
# STEP 12: CREATE  BIOS PXELINUX CONFIGURATION
# ==============================================
log_info "Generating BIOS PXELINUX configuration..."

logging sudo bash -c "cat > $PXE_CFG << EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
ONTIMEOUT desktop.22.04.5

MENU TITLE Unified BIOS+UEFI PXE  Server

EOF"

# PXELINUX Dynamic ISO entries FIRST
ISO_FILES=( "$DOWNLOAD_DIR"/*.iso )
for i in "${!ISO_FILES[@]}"; do
    iso_name=$(basename "${ISO_FILES[$i]}")
    version=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<< "$iso_name")
    distro_name="${TYPES[$i]}.${VERSIONS[$i]}"

    # Decide autoinstall source dynamically
    case "${TYPES[$i]}" in
        desktop) user_data="desktop" ;;
        server)  user_data="server" ;;
        *)       user_data="server" ;;
    esac

    # Append line variable (PXE)
    # autoinstall cloud-config-url=http://$SERVER_IP/auto-install/${user_data}/user-data ---
    # cloud-config-url=/dev/null maybe-ubiquity autoinstall ds=nocloud-net;s=http://$SERVER_IP/auto-install/${user_data}/
    append_default="ip=dhcp rd.systemd.network=0 netboot=nfs nfsroot=$SERVER_IP:$WEB_ROOT/${distro_name} ro boot=casper"
    subiquity="autoinstall cloud-config-url=http://$SERVER_IP/auto-install/${user_data}/user-data-bios ---"
    ubiquity="automatic-ubiquity noprompt keyboard-configuration/layoutcode=gb locale=en_GB.UTF-8 url=http://$SERVER_IP/auto-install/${user_data}/preseed-bios.cfg priority=critical d-i ubiquity/minimal_install=true ubiquity/download_updates=false reboot=pci noprompt nosplash debug ---"


    #  Special case: Ubuntu Desktop 22.04 → Ubiquity + preseed
    automatic_install="$subiquity"
    if [[ "${TYPES[$i]}" == "desktop" && "${VERSIONS[$i]}" == 22* ]]; then
       automatic_install="$ubiquity"
    fi

    log_info "Adding PXE entries: ${distro_name}-${version} (AUTO + MANUAL)"

    # --- AUTO INSTALL entry ---
    logging sudo bash -c "cat >> $PXE_CFG << EOF
LABEL ${distro_name}
    MENU LABEL ${distro_name^} (AUTO INSTALL)
    KERNEL boot/casper/${distro_name}/vmlinuz
    INITRD boot/casper/${distro_name}/initrd
    APPEND ${append_default} ${automatic_install}
EOF"

    # --- MANUAL INSTALL entry ---
    logging sudo bash -c "cat >> $PXE_CFG << EOF
LABEL ${distro_name}-manual
    MENU LABEL ${distro_name^} (Manual)
    KERNEL boot/casper/${distro_name}/vmlinuz
    INITRD boot/casper/${distro_name}/initrd
    APPEND ${append_default} ---
EOF"
done

# Static entries
log_info "Adding PXE static entries..."

logging sudo bash -c "cat >> $PXE_CFG << EOF

LABEL local
    MENU LABEL Boot from local disk (BIOS/UEFI)
    LOCALBOOT 0

LABEL memtest
    MENU LABEL Memory Test (Memtest86+)
    KERNEL memtest86+.bin
EOF"

# ==============================================
# STEP 13: CREATE UEFI GRUB CONFIGURATION
# ==============================================
log_info "Generating UEFI GRUB configuration..."

logging sudo bash -c "cat > $GRUB_CFG << 'EOF'
set net_default_interface=auto
set prefix=(tftp,$SERVER_IP)/grub
insmod net
insmod efinet
insmod tftp
insmod http

set timeout=50
loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
EOF"

# GRUB Dynamic ISO entries FIRST
ISO_FILES=( "$DOWNLOAD_DIR"/*.iso )
for i in "${!ISO_FILES[@]}"; do
    iso_name=$(basename "${ISO_FILES[$i]}")
    version=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<< "$iso_name")
    distro_name="${TYPES[$i]}.${VERSIONS[$i]}"

    # Decide autoinstall source dynamically
    case "${TYPES[$i]}" in
        desktop) user_data="desktop" ;;
        server)  user_data="server" ;;
        *)       user_data="server" ;;
    esac

    # Same as PXE Append line variable
    append_default="ip=dhcp rd.systemd.network=0 netboot=nfs nfsroot=$SERVER_IP:$WEB_ROOT/${distro_name} ro boot=casper"
    subiquity="autoinstall cloud-config-url=http://$SERVER_IP/auto-install/${user_data}/user-data-uefi ---"
    ubiquity="automatic-ubiquity noprompt keyboard-configuration/layoutcode=gb locale=en_GB.UTF-8 url=http://$SERVER_IP/auto-install/${user_data}/preseed-uefi.cfg priority=critical d-i ubiquity/minimal_install=true ubiquity/download_updates=false reboot=pci noprompt nosplash debug ---"

    # Special case: Ubuntu Desktop 22.04 → Ubiquity + preseed
    automatic_install="$subiquity"

    if [[ "${TYPES[$i]}" == "desktop" && "${VERSIONS[$i]}" == 22* ]]; then
       append_default="$append_default"
       automatic_install="$ubiquity"
    fi

    log_info "Adding GRUB entries: ${distro_name^} ${version} (AUTO + MANUAL)"

    # --- AUTO INSTALL entry ---
    logging sudo bash -c "cat >> $GRUB_CFG << EOF
menuentry '${distro_name^} (AUTO INSTALL)' {
    linux /bios/boot/casper/${distro_name}/vmlinuz ${append_default} ${automatic_install}
    initrd /bios/boot/casper/${distro_name}/initrd
}
EOF"

    # --- MANUAL entry ---
    logging sudo bash -c "cat >> $GRUB_CFG << EOF
menuentry '${distro_name^} (Manual)' {
    linux /bios/boot/casper/${distro_name}/vmlinuz ${append_default} ---
    initrd /bios/boot/casper/${distro_name}/initrd
}
EOF"
done

# Static GRUB entries
log_info "Adding GRUB static entries..."

logging sudo bash -c "cat >> $GRUB_CFG << 'EOF'

menuentry 'Boot from next volume' {
    exit 1
}

menuentry 'UEFI Firmware Settings' {
    fwsetup
}

menuentry 'Memory Test (Memtest86+)' {
    linux /boot/memtest86+.bin
}
EOF"

ln -sf "$TFTP_ROOT/grub/grub.cfg" "$TFTP_ROOT/efi/boot/grub/grub.cfg"
ln -sf "$TFTP_ROOT/grub/grub.cfg" "$TFTP_ROOT/grub.cfg"

# ===================
# AUTO-INSTALL CONFIG
# ===================
#---------------------------------------------------------------------------------
#                Desktop USER-DATA config for BIOS clients
#---------------------------------------------------------------------------------
log_info "Creating DESKTOP SUBIQUITY autoinstall configuration...for ....LEGACY BIOS"


logging sudo tee "$DESKTOP_CONFIG/user-data-bios" > /dev/null <<'EOF'
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []

  refresh-installer:
    update: false
  updates: false

  ssh:
    install-server: true
    allow-pw: true

  drivers:
    install: false
  source:
    id: ubuntu-desktop-minimal


  identity:
    hostname: newsystem
    username: ubuntu
    password: '$6$2mgdYOl8vTups5VH$XZb0UyLv7URen7un9OMlhy/Rv7A9HOgSktE9KvP5aiNAiVQmd9by/odMMAetc7J5FBDqed1mtgZj2UNqk4f43.'
    realname: Admin

  # Regional Settings
  locale: en_GB.UTF-8
  timezone: Europe/London
  keyboard:
    layout: gb
    variant: ""

  # BIOS GPT partition
  storage:
    config:
      - id: disk-sda
        type: disk
        ptable: gpt
        path: /dev/sda
        wipe: superblock-recursive
        preserve: false
        grub_device: true

      - id: bios-boot
        type: partition
        device: disk-sda
        size: 1M
        flag: bios_grub

      - id: partition-root
        type: partition
        device: disk-sda
        size: -1

      - id: format-root
        type: format
        fstype: ext4
        volume: partition-root

      - id: mount-root
        type: mount
        device: format-root
        path: /
  late-commands:
    - curtin in-target -- systemctl disable unattended-upgrades
    - curtin in-target -- systemctl disable apport.service
    - curtin in-target -- systemctl stop apport.service
    - curtin in-target -- reboot

#late-commands:
#  - curtin in-target --target=/target -- systemctl disable apport.service
#  - curtin in-target --target=/target -- systemctl stop apport.service
#  - curtin in-target --target=/target -- reboot
  updates: security
  shutdown: reboot
EOF

log_info "Creating meta-data..."

logging sudo bash -c "cat > $DESKTOP_CONFIG/meta-data << EOF
instance-id: iid-ubuntu2404-desktop
local-hostname: ubuntu-desktop
EOF"

log_info "Ensuring vendor-data exists..."
logging sudo touch $DESKTOP_CONFIG/vendor-data


#---------------------------------------------------------------------------------
#              Desktop USER-DATA config data for (UEFI clients)
#---------------------------------------------------------------------------------
log_info "Creating DESKTOP SUBIQUITY autoinstall configuration...for ....UEFI clients"

logging sudo tee "$DESKTOP_CONFIG/user-data-uefi" > /dev/null <<'EOF'
#cloud-config
autoinstall:
  version: 1
  interactive-sections: []

  refresh-installer:
    update: false

  updates: security

  ssh:
    install-server: true
    allow-pw: true

  drivers:
    install: false

  source:
    id: ubuntu-desktop-minimal

  identity:
    hostname: newsystem
    username: ubuntu
    password: '$6$2mgdYOl8vTups5VH$XZb0UyLv7URen7un9OMlhy/Rv7A9HOgSktE9KvP5aiNAiVQmd9by/odMMAetc7J5FBDqed1mtgZj2UNqk4f43.'
    realname: Admin

  locale: en_GB.UTF-8
  timezone: Europe/London

  keyboard:
    layout: gb
    variant: ""

  storage:
    layout:
      name: direct
      match:
        # This targets the first available drive.
        # Change to a specific ID if you have multiple drives.
        size: largest
  late-commands:
    - curtin in-target -- systemctl disable unattended-upgrades
    - curtin in-target -- systemctl disable apport.service
    - curtin in-target -- systemctl stop apport.service

  shutdown: reboot
EOF

#-------------------------------------------------------------------------------------------
#                  SERVER user-data for BIOS boot
#-----------------------------------------------------------------------------------------
log_info "Creating SERVER ..SUBIQUITY autoinstall configuration...for ....LEGACY BIOS"

logging sudo tee "$SERVER_CONFIG/user-data-bios" > /dev/null <<'EOF'
#cloud-config
autoinstall:
  version: 1

  apt:
    disable_components: []
    fallback: offline-install

  keyboard:
    layout: gb
    toggle: null
    variant: ''

  locale: en_GB.UTF-8
  timezone: Europe/London

  identity:
    hostname: newsystem
    username: ubuntu
    password: '$6$2mgdYOl8vTups5VH$XZb0UyLv7URen7un9OMlhy/Rv7A9HOgSktE9KvP5aiNAiVQmd9by/odMMAetc7J5FBDqed1mtgZj2UNqk4f43.'
    realname: Admin

  package_update: false
  package_upgrade: false

    packages:
    - ubuntu-desktop-minimal
    - autossh
    - black
    - baobab
    - curl
    - dos2unix
    - dbus-x11
    - git
    - gnupg2
    - isort
    - libcups2-dev
    - libglib2.0-dev-bin
    - libmpv2
    - libcanberra-gtk-module
    - libsecret-tools
    - moreutils
    - ncdu
    - nmap
    - net-tools
    - openssh-server
    - python3-sh
    - python3-requests
    - python3-venv
    - python3-dev
    - python3-serial
    - python-is-python3
    - tree
    - timeshift
    - supervisor
    - software-properties-common
    - terminator
    - wget
    - xserver-xorg

  late-commands:
    - curtin in-target --target=/target systemctl set-default graphical.target
    - curtin in-target -- systemctl disable unattended-upgrades
  updates: security
  shutdown: reboot

EOF

log_info "Creating meta-data..."

logging sudo bash -c "cat > $SERVER_CONFIG/meta-data << EOF
instance-id: iid-local01
local-hostname: ubuntu
EOF"

log_info "Ensuring vendor-data exists..."
logging sudo touch $SERVER_CONFIG/vendor-data

#
#-------------------------------------------------------------------------------------------
#              SERVER user-data for UEFI boot
#-----------------------------------------------------------------------------------------
log_info "Creating SERVER ..SUBIQUITY autoinstall configuration...for ....LEGACY BIOS"

logging sudo tee "$SERVER_CONFIG/user-data-uefi" > /dev/null <<'EOF'
#cloud-config
autoinstall:
  version: 1

  apt:
    disable_components: []
    fallback: offline-install

  keyboard:
    layout: gb
    toggle: null
    variant: ''

  locale: en_GB.UTF-8
  timezone: Europe/London

  identity:
    hostname: newsystem
    username: ubuntu
    password: '$6$2mgdYOl8vTups5VH$XZb0UyLv7URen7un9OMlhy/Rv7A9HOgSktE9KvP5aiNAiVQmd9by/odMMAetc7J5FBDqed1mtgZj2UNqk4f43.'
    realname: Admin

  package_update: false
  package_upgrade: false

    packages:
    - ubuntu-desktop-minimal
    - autossh
    - black
    - baobab
    - curl
    - dos2unix
    - dbus-x11
    - git
    - gnupg2
    - isort
    - libcups2-dev
    - libglib2.0-dev-bin
    - libmpv2
    - libcanberra-gtk-module
    - libsecret-tools
    - moreutils
    - ncdu
    - nmap
    - net-tools
    - openssh-server
    - python3-sh
    - python3-requests
    - python3-venv
    - python3-dev
    - python3-serial
    - python-is-python3
    - tree
    - timeshift
    - supervisor
    - software-properties-common
    - terminator
    - wget
    - xserver-xorg

  late-commands:
    - curtin in-target --target=/target systemctl set-default graphical.target
    - curtin in-target -- systemctl disable unattended-upgrades
  updates: security
  shutdown: reboot

EOF

log_info "Creating meta-data..."

logging sudo bash -c "cat > $SERVER_CONFIG/meta-data << EOF
instance-id: iid-local01
local-hostname: ubuntu
EOF"

log_info "Ensuring vendor-data exists..."
logging sudo touch $SERVER_CONFIG/vendor-data

#-------------------------------------------------------------------------------------------
#        Ubuntu 22.04 LTS Desktop preseed config for (BIOS boot)
#-----------------------------------------------------------------------------------------
log_info "Creating UBIQUITY autoinstall configuration..."

logging sudo tee "$DESKTOP_CONFIG/preseed-bios.cfg" > /dev/null <<'EOF'
# --- Localization ---
d-i debian-installer/locale string en_GB.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select gb

# --- Network Configuration ---
# Force netcfg to not hang if DHCP is slow
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ubuntu-desktop
d-i netcfg/get_domain string unassigned-domain
# Ensure a global DNS is used if the local DHCP doesn't provide a reliable one
d-i netcfg/get_nameservers string 8.8.8.8 1.1.1.1
d-i netcfg/confirm_static boolean true

# --- Mirror Settings ---
# This section is likely where your crash happened.
# We use 'cc' to auto-select the best mirror based on the country.
d-i mirror/country string US
d-i mirror/http/hostname string archive.ubuntu.com
d-i mirror/http/directory string /ubuntu
d-i mirror/http/proxy string
# This line is CRITICAL: it tells the installer to continue even if the mirror check fails initially
d-i mirror/protocol string http
d-i mirror/error/could-not-contact-mirror boolean true

# --- Account Setup ---
d-i passwd/user-fullname string Admin
d-i passwd/username string ubuntu
d-i passwd/user-password password ubuntu12*&
d-i passwd/user-password-again password ubuntu12*&
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false

# --- Clock and Timezone ---
d-i clock-setup/utc boolean true
d-i time/zone string Europe/London
d-i clock-setup/ntp boolean true

# --- Partitioning ---
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# --- THE MINIMAL INSTALL FIXES ---
d-i ubiquity/minimal_install boolean true
ubiquity ubiquity/minimal_install boolean true
ubiquity ubiquity/download_updates boolean false
ubiquity ubiquity/use_nonfree boolean false

# --- Package Selection ---
# NOTE: If this fails, your LAN has no internet access.
# The installer will crash here if it can't download these.
d-i pkgsel/include string openssh-server build-essential
d-i pkgsel/upgrade select none
d-i pkgsel/update-policy select none
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

# --- late_command, copy windows share ---
d-i preseed/late_command string \
in-target apt-get update || true; \
in-target apt-get install -y cifs-utils openssh-server || true; \
in-target systemctl enable ssh || true; \
mkdir -p /target/mnt/smb; \
timeout 45 sh -c '\
  mount -t cifs //10.10.67.7/data /target/mnt/smb -o username=marolee,password=1984,vers=3.0,nofail && \
  cp -r /target/mnt/smb/d-drive/bts_onsite/server-prep /target/home/ubuntu/ && \
  chown -R 1000:1000 /target/home/ubuntu/server-prep && \
  umount -l /target/mnt/smb \
' || true

# --- Finishing the Installation ---
d-i finish-install/reboot_inplace boolean true
EOF

#-------------------------------------------------------------------------------------------
#      Ubuntu 22.04 LTS  Desktop preseed config for (UEFI boot)
#-----------------------------------------------------------------------------------------
logging sudo tee "$DESKTOP_CONFIG/preseed-uefi.cfg" > /dev/null <<'EOF'
# --- Localization ---
d-i debian-installer/locale string en_GB.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select gb

# --- Network Configuration ---
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ubuntu-desktop
d-i netcfg/get_domain string unassigned-domain
d-i netcfg/get_nameservers string 8.8.8.8 1.1.1.1
d-i netcfg/confirm_static boolean true

# --- Mirror Settings (same safety as BIOS) ---
d-i mirror/country string US
d-i mirror/http/hostname string archive.ubuntu.com
d-i mirror/http/directory string /ubuntu
d-i mirror/http/proxy string
d-i mirror/protocol string http
d-i mirror/error/could-not-contact-mirror boolean true

# --- Account Setup ---
d-i passwd/user-fullname string Admin
d-i passwd/username string ubuntu
d-i passwd/user-password password ubuntu12*&
d-i passwd/user-password-again password ubuntu12*&
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false

# --- Clock and Timezone ---
d-i clock-setup/utc boolean true
d-i time/zone string Europe/London
d-i clock-setup/ntp boolean true

# --- Partitioning (UEFI but BIOS-like) ---
d-i partman-auto/method string lvm

# KEY DIFFERENCE: force GPT for UEFI
d-i partman-partitioning/default_label string gpt

# Ensure EFI partition is created automatically
d-i partman-efi/non_efi_system boolean true

# Cleanup old configs (same as BIOS)
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true

# Keep SAME simple recipe as BIOS
d-i partman-auto/choose_recipe select atomic

# Confirm everything
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# --- Ubiquity minimal install (same as BIOS) ---
d-i ubiquity/minimal_install boolean true
ubiquity ubiquity/minimal_install boolean true
ubiquity ubiquity/download_updates boolean false
ubiquity ubiquity/use_nonfree boolean false

# --- Package Selection ---
d-i pkgsel/include string openssh-server build-essential
d-i pkgsel/upgrade select none
d-i pkgsel/update-policy select none

# --- GRUB ---
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

# --- late_command ---
d-i preseed/late_command string \
in-target apt-get update || true; \
in-target apt-get install -y cifs-utils openssh-server || true; \
in-target systemctl enable ssh || true;


# --- Finish ---
d-i finish-install/reboot_inplace boolean true
EOF

# ==============================================
# FINAL
# ==============================================
if ! $SKIP_SERVICES; then
    log_info "Starting services..."
    logging sudo ufw disable
    logging sudo systemctl --quiet enable apache2 nfs-kernel-server dnsmasq
    logging sudo systemctl --quiet start apache2 nfs-kernel-server dnsmasq

    log_info "Verifying services..."
    logging sudo systemctl --no-pager status apache2
    logging sudo systemctl --no-pager status nfs-kernel-server
    logging sudo systemctl --no-pager status dnsmasq
else
    log_info "Skipping service start/verification"
fi

log_info "Server preparation completed"

#multitail /var/log/apache2/access.log -l "journalctl -u dnsmasq -f"
journalctl -u dnsmasq -f
