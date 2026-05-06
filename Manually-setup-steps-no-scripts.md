# Ubuntu PXE + NFS + Autoinstall Server Setup (Manual setup) 

## Overview

This project builds a **fully automated network boot (PXE) infrastructure** for deploying Ubuntu desktops and servers over LAN with zero USB/DVD installation required.

It combines multiple services into a single deployment system:

- **PXE Boot (BIOS + UEFI)** using Syslinux + GRUB
- **DHCP/TFTP server** via dnsmasq
- **HTTP ISO hosting** via Apache
- **NFS root filesystem sharing**
- **Unattended Ubuntu installation (Autoinstall + Preseed)**
- Support for:
  - Ubuntu 22.04.5 LTS
  - Ubuntu 24.04.4 LTS

## What this setup does

Once deployed, any machine connected to the network can:

1. Boot via **PXE (network boot)**
2. Receive IP + bootloader automatically (DHCP)
3. Load boot menu (BIOS or UEFI)
4. Select:
   - Ubuntu 22.04.5 (Auto Install or Manual)
   - Ubuntu 24.04.4 (Auto Install or Manual)
   - Memory test (Memtest86+)
   - Local disk boot
5. Install Ubuntu automatically using:
   - Cloud-init autoinstall (Subiquity)
   - Ubiquity preseed (legacy BIOS desktop installs)
6. Mount OS root via **NFS or local ISO extraction**
7. Complete installation without user interaction

## Architecture

- **dnsmasq** → DHCP + PXE + TFTP
- **Apache2** → ISO + autoinstall config hosting
- **NFS server** → Ubuntu filesystem sharing
- **Syslinux** → BIOS PXE bootloader
- **GRUB EFI** → UEFI PXE bootloader

## Key Features

- Unified BIOS + UEFI PXE support
- Fully automated OS deployment
- Dual Ubuntu version support
- Network-based ISO streaming (no USB required)
- Centralized autoinstall configuration
- Supports both desktop and server installs
- Scalable for labs, enterprises, and homelabs

## Target Use Cases

- IT lab automation
- School / university computer deployment
- Enterprise workstation provisioning
- Homelab OS testing environments
- Bare-metal recovery and reinstall systems

---

## STEP 1: Create Directories

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
```

---

## STEP 2: Download ISO

```bash
wget -c -O "/var/www/html/iso_images/ubuntu-22.04.5-desktop-amd64.iso" "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso"
wget -c -O "/var/www/html/iso_images/ubuntu-24.04.4-desktop-amd64.iso" "https://releases.ubuntu.com/noble/ubuntu-24.04.4-desktop-amd64.iso"
```

---

## STEP 3: Mount, Copy, Unmount — Ubuntu 22.04.5

```bash
mountpoint -q /mnt/ubuntu-22.04.5 && sudo umount -l /mnt/ubuntu-22.04.5

sudo mount -o loop,ro /var/www/html/iso_images/ubuntu-22.04.5-desktop-amd64.iso /mnt/ubuntu-22.04.5

rsync -a --delete --ignore-existing --info=progress2,stats /mnt/ubuntu-22.04.5/ /var/www/html/ubuntu/22.04.5/

sudo umount /mnt/ubuntu-22.04.5
```

---

## STEP 4: Mount, Copy, Unmount — Ubuntu 24.04.4

```bash
mountpoint -q /mnt/ubuntu-24.04.4 && sudo umount -l /mnt/ubuntu-24.04.4

sudo mount -o loop,ro /var/www/html/iso_images/ubuntu-24.04.4-desktop-amd64.iso /mnt/ubuntu-24.04.4

rsync -a --delete --ignore-existing --info=progress2,stats /mnt/ubuntu-24.04.4/ /var/www/html/ubuntu/24.04.4/

sudo umount /mnt/ubuntu-24.04.4
```

---

## STEP 5: Stop Conflicting Services

```bash
sudo systemctl stop apache2 nfs-kernel-server dnsmasq nginx
sudo systemctl disable apache2 nfs-kernel-server dnsmasq nginx
```

---

## STEP 6: Install Required Apps

```bash
sudo apt-get update -y
sudo apt-get --fix-broken install -y
sudo apt-get install -y multitail apache2 dnsmasq nfs-kernel-server wget syslinux grub-efi-amd64-signed shim-signed grub-efi-amd64-bin memtest86+
```

---

## STEP 7: Configure NFS

```bash
sudo cp /etc/exports /etc/exports.bak.$(date +%F_%T)
sudo truncate -s 0 /etc/exports

echo "/var/www/html/ubuntu/22.04.5 *(ro,sync,no_wdelay,insecure_locks,no_root_squash,insecure,no_subtree_check)" | sudo tee -a /etc/exports > /dev/null
echo "/var/www/html/ubuntu/24.04.4 *(ro,sync,no_wdelay,insecure_locks,no_root_squash,insecure,no_subtree_check)" | sudo tee -a /etc/exports > /dev/null

sudo exportfs -ra
sudo systemctl restart nfs-kernel-server
```

---

## STEP 8: Configure dnsmasq

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

## STEP 9: PXE BIOS + GRUB Files

```bash
wget -q --show-progress -cO /tmp/syslinux-6.04-pre1.tar.gz \
https://mirrors.edge.kernel.org/pub/linux/utils/boot/syslinux/Testing/6.04/syslinux-6.04-pre1.tar.gz

tar -xvzf /tmp/syslinux-6.04-pre1.tar.gz -C /tmp

sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/elflink/ldlinux/ldlinux.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/libutil/libutil.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/menu/menu.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/com32/menu/vesamenu.c32 /tftp/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/core/pxelinux.0 /tftp/bios/
sudo cp -u /tmp/syslinux-6.04-pre1/bios/core/lpxelinux.0 /tftp/bios/

rm -rf /tmp/syslinux-6.04-pre1 /tmp/syslinux-6.04-pre1.tar.gz
```

---

## STEP 10: Kernel + Initrd Copy

```bash
sudo mkdir -p /tftp/bios/boot/casper/22.04.5
sudo mkdir -p /tftp/bios/boot/casper/24.04.4
```

---

## STEP 11: PXELINUX Menu

```bash
sudo tee /tftp/bios/pxelinux.cfg/default > /dev/null <<'EOF'
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
ONTIMEOUT ubuntu.22.04.5

MENU TITLE Unified BIOS+UEFI PXE Server
EOF
```

---

## STEP 12: GRUB UEFI Config

```bash
sudo tee /tftp/grub/grub.cfg > /dev/null <<'EOF'
set net_default_interface=auto
set prefix=(tftp,<SERVER_IP>)/grub

insmod net
insmod efinet
insmod tftp
insmod http

set timeout=50
loadfont unicode

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray
EOF
```

---

## STEP 13: Autoinstall Configs

[Includes here:](auto-install)

- user-data-bios
- user-data-uefi
- server configs
- preseed BIOS + UEFI

---

## FINAL SERVICE START

```bash
sudo ufw disable

sudo systemctl enable apache2 nfs-kernel-server dnsmasq
sudo systemctl start apache2 nfs-kernel-server dnsmasq
```

---

## Monitoring Commands

```bash
systemctl is-active apache2 nfs-kernel-server dnsmasq

sudo journalctl -u dnsmasq -f
sudo tail -f /var/log/apache2/access.log
sudo journalctl -u nfs-kernel-server -f
```

---

## DEBUGGING (3-Terminal View)

```bash
Terminal 1:
sudo journalctl -u dnsmasq -f

Terminal 2:
sudo tail -f /var/log/apache2/access.log

Terminal 3:
sudo journalctl -u nfs-kernel-server -f
```
