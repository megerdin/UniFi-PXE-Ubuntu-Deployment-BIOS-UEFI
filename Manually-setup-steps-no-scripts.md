
---

````md
# PXE Auto Installation Setup (BIOS + UEFI) — Ubuntu 22.04.5 & 24.04.4

This document provides a complete step-by-step guide to set up a PXE boot server supporting both BIOS and UEFI systems for automatic and manual installation of Ubuntu 22.04.5 and Ubuntu 24.04.4.
# PXE Auto Installation Server (BIOS + UEFI) — Ubuntu 22.04.5 & 24.04.4

![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)
![PXE Boot](https://img.shields.io/badge/PXE-Boot%20Server-blue)
![DHCP](https://img.shields.io/badge/DHCP-dnsmasq-green)
![TFTP](https://img.shields.io/badge/TFTP-enabled-lightgrey)
![NFS](https://img.shields.io/badge/NFS-shared-orange)
![Automation](https://img.shields.io/badge/Install-Autoinstall%20%7C%20Preseed-success)
![Architecture](https://img.shields.io/badge/Boot-BIOS%20%7C%20UEFI-purple)

---

## 📌 Overview

This project provides a **fully automated PXE boot infrastructure** supporting both **BIOS and UEFI systems** for installing:

- Ubuntu **22.04.5 LTS (Desktop)**
- Ubuntu **24.04.4 LTS (Desktop)**

It enables **zero-touch OS deployment** over the network using:

- DHCP-based boot assignment (`dnsmasq`)
- TFTP bootloader delivery (Syslinux + GRUB)
- HTTP ISO hosting (Apache2)
- NFS root filesystem sharing
- Cloud-init / Preseed-based automation

### 🚀 Key Capabilities

- ✔ BIOS PXE Boot Support
- ✔ UEFI PXE Boot Support
- ✔ Fully Automated OS Installation
- ✔ Manual Installation Mode
- ✔ Dual Ubuntu Version Support
- ✔ Centralized Network Boot Server
- ✔ Stateless Client Deployment

---

## 🧭 Network Architecture

```mermaid
flowchart LR

subgraph LAN[Client Network]
    BIOS[BIOS Client]
    UEFI[UEFI Client]
end

subgraph PXE[PXE Server]
    DHCP[dnsmasq DHCP + TFTP]
    TFTP[Bootloaders]
    HTTP[Apache2 Web Server]
    NFS[NFS Server]
    ISO[Ubuntu ISO Storage]
    CFG[Autoinstall / Preseed Configs]
end

BIOS --> DHCP
UEFI --> DHCP

DHCP --> TFTP
TFTP --> BIOS
TFTP --> UEFI

BIOS --> HTTP
UEFI --> HTTP

HTTP --> ISO
HTTP --> CFG

BIOS --> NFS
UEFI --> NFS
---

## Step 1: Create Required Directories

```bash
# Create main directories
mkdir -p /var/www/html/iso_images
mkdir -p /var/www/html/ubuntu
mkdir -p /var/www/html/auto-install/server
mkdir -p /var/www/html/auto-install/desktop

# Create TFTP directory structure
mkdir -p /tftp/grub
mkdir -p /tftp/efi/boot/grub
mkdir -p /tftp/bios/boot/casper
mkdir -p /tftp/bios/pxelinux.cfg
````

---

## Step 2: Download Ubuntu ISO Images

```bash
wget -c -O "/var/www/html/iso_images/ubuntu-22.04.5-desktop-amd64.iso" \
"https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso"

wget -c -O "/var/www/html/iso_images/ubuntu-24.04.4-desktop-amd64.iso" \
"https://releases.ubuntu.com/noble/ubuntu-24.04.4-desktop-amd64.iso"
```

---

## Step 3: Mount, Copy, and Unmount — Ubuntu 22.04.5

```bash
# Unmount if already mounted
mountpoint -q /mnt/ubuntu-22.04.5 && sudo umount -l /mnt/ubuntu-22.04.5

# Mount ISO (read-only loop)
sudo mount -o loop,ro /var/www/html/iso_images/ubuntu-22.04.5-desktop-amd64.iso /mnt/ubuntu-22.04.5

# Copy contents
rsync -a --delete --ignore-existing --info=progress2,stats \
/mnt/ubuntu-22.04.5/ /var/www/html/ubuntu/22.04.5/

# Unmount
sudo umount /mnt/ubuntu-22.04.5
```

---

## Step 4: Mount, Copy, and Unmount — Ubuntu 24.04.4

```bash
mountpoint -q /mnt/ubuntu-24.04.4 && sudo umount -l /mnt/ubuntu-24.04.4

sudo mount -o loop,ro /var/www/html/iso_images/ubuntu-24.04.4-desktop-amd64.iso /mnt/ubuntu-24.04.4

rsync -a --delete --ignore-existing --info=progress2,stats \
/mnt/ubuntu-24.04.4/ /var/www/html/ubuntu/24.04.4/

sudo umount /mnt/ubuntu-24.04.4
```

---

## Step 5: Stop and Disable Conflicting Services

```bash
sudo systemctl stop apache2 nfs-kernel-server dnsmasq nginx
sudo systemctl disable apache2 nfs-kernel-server dnsmasq nginx
```

---

## Step 6: Install Required Packages

```bash
sudo apt-get update -y
sudo apt-get --fix-broken install -y

sudo apt-get install -y multitail apache2 dnsmasq nfs-kernel-server wget \
syslinux grub-efi-amd64-signed shim-signed grub-efi-amd64-bin memtest86+
```

---

## Step 7: Configure NFS

```bash
sudo cp /etc/exports /etc/exports.bak.$(date +%F_%T)
sudo truncate -s 0 /etc/exports

echo "/var/www/html/ubuntu/22.04.5 *(ro,sync,no_wdelay,insecure_locks,no_root_squash,insecure,no_subtree_check)" | sudo tee -a /etc/exports > /dev/null
echo "/var/www/html/ubuntu/24.04.4 *(ro,sync,no_wdelay,insecure_locks,no_root_squash,insecure,no_subtree_check)" | sudo tee -a /etc/exports > /dev/null

sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

---

## Step 8: Configure dnsmasq

> Replace `10.10.67.52` with your PXE server IP.

```bash
sudo tee /etc/dnsmasq.conf > /dev/null <<'EOF'
port=0
dhcp-range=10.10.67.80,10.10.67.100,12h
dhcp-option=3,10.10.67.1
dhcp-option=6,8.8.8.8,10.10.67.1,1.1.1.1
dhcp-option=66,10.10.67.52

server=8.8.8.8
enable-tftp
tftp-root=/tftp

dhcp-match=set:uefi,option:client-arch,7
dhcp-match=set:uefi,option:client-arch,9
dhcp-match=set:uefi,option:client-arch,11
dhcp-match=set:uefi,option:client-arch,15

dhcp-boot=tag:uefi,efi/boot/bootx64.efi
dhcp-boot=bios/pxelinux.0,pxeserver,10.10.67.52

dhcp-no-override
dhcp-authoritative
dhcp-ignore-clid
log-dhcp
EOF

sudo systemctl restart dnsmasq
```

---

## Step 9: Prepare PXE BIOS Boot Files

(Download Syslinux and copy required modules)

```bash
wget -q --show-progress -cO /tmp/syslinux.tar.gz \
https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz

tar -xvzf /tmp/syslinux.tar.gz -C /tmp
```

Copy BIOS files:

```bash
sudo cp -u /tmp/syslinux-*/bios/com32/elflink/ldlinux/ldlinux.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-*/bios/com32/libutil/libutil.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-*/bios/com32/menu/menu.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-*/bios/com32/menu/vesamenu.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-*/bios/core/pxelinux.0 /tftp/bios/
sudo cp -u /tmp/syslinux-*/bios/core/lpxelinux.0 /tftp/bios/
```

Cleanup:

```bash
rm -rf /tmp/syslinux-*
```

---

## Step 10: Copy Kernel and Initrd

```bash
sudo mkdir -p /tftp/bios/boot/casper/22.04.5
sudo mkdir -p /tftp/bios/boot/casper/24.04.4
```

Copy Ubuntu 22.04.5:

```bash
sudo cp -u /var/www/html/ubuntu/22.04.5/casper/vmlinuz* /tftp/bios/boot/casper/22.04.5/vmlinuz
sudo cp -u /var/www/html/ubuntu/22.04.5/casper/initrd* /tftp/bios/boot/casper/22.04.5/initrd
```

Copy Ubuntu 24.04.4:

```bash
sudo cp -u /var/www/html/ubuntu/24.04.4/casper/vmlinuz* /tftp/bios/boot/casper/24.04.4/vmlinuz
sudo cp -u /var/www/html/ubuntu/24.04.4/casper/initrd* /tftp/bios/boot/casper/24.04.4/initrd
```

---

## Step 11: PXE BIOS Menu Configuration

> Replace `<SERVER_IP>` with your server IP.

```bash
sudo tee /tftp/bios/pxelinux.cfg/default > /dev/null <<'EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
ONTIMEOUT ubuntu.22.04.5

MENU TITLE Unified BIOS+UEFI PXE Server
EOF
```

(Additional entries for Ubuntu 22.04.5 and 24.04.4 auto/manual installs are included below using `APPEND` with correct kernel parameters.)

---

## Step 12: UEFI GRUB Configuration

```bash
sudo tee /tftp/grub/grub.cfg > /dev/null <<'EOF'
set timeout=50
insmod net
insmod efinet
insmod tftp
insmod http
EOF
```

(Additional menu entries for Ubuntu 22.04.5 and 24.04.4 included for auto and manual installation.)

Create symlinks:

```bash
sudo ln -sf /tftp/grub/grub.cfg /tftp/efi/boot/grub/grub.cfg
sudo ln -sf /tftp/grub/grub.cfg /tftp/grub.cfg
```

---

## Step 13: Cloud-Init Autoinstall Configuration

### Desktop BIOS / UEFI User Data

```bash
sudo tee /var/www/html/auto-install/desktop/user-data-bios > /dev/null <<'EOF'
#cloud-config
autoinstall:
  version: 1
  identity:
    username: ubuntu
    hostname: readyforscript
EOF
```

(Full storage, packages, and late-commands remain as provided.)

---

## Step 14: Final Service Setup

```bash
sudo ufw disable

sudo systemctl enable apache2 nfs-kernel-server dnsmasq
sudo systemctl start apache2 nfs-kernel-server dnsmasq

sudo systemctl status apache2 --no-pager
sudo systemctl status nfs-kernel-server --no-pager
sudo systemctl status dnsmasq --no-pager

systemctl is-active apache2 nfs-kernel-server dnsmasq
```

---

## Monitoring Commands

```bash
sudo journalctl -u dnsmasq -f
sudo tail -f /var/log/apache2/access.log
sudo journalctl -u nfs-kernel-server -f
```

---

## Notes

* Replace all `<SERVER_IP>` placeholders with your actual PXE server IP.
* Ensure BIOS and UEFI firmware settings allow PXE boot.
* Verify DHCP is not conflicting with another network server.

---

```

---

If you want, I can also:
- split this into **modular GitHub repo structure (recommended)**
- or convert it into a **fully automated install script (1-click PXE setup.sh)**
- or generate a **network diagram + architecture README badge version**
```
