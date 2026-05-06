# 🚀 (Manual) Ubuntu PXE Auto-Install Server (BIOS + UEFI)

Fully automated PXE boot environment for Ubuntu Desktop & Server using:

* **dnsmasq** (DHCP + TFTP)
* **NFS** (root filesystem)
* **Apache** (autoinstall configs)
* Supports **BIOS + UEFI**
* Supports **autoinstall (Subiquity)** and **preseed (22.04 Desktop)**

---

# 📦 Features

* Multi-ISO support (auto-detected)
* Automatic PXE menu generation
* Separate configs for:

  * Desktop / Server
  * BIOS / UEFI
* Fully unattended installation
* Optional “manual install” boot entries
* Fast update mode (`--update`)

---

# ⚠️ IMPORTANT WARNINGS

### 🚨 DHCP CONFLICT

This script **runs a DHCP server**.

> ❗ Do NOT run on a network with an existing DHCP server
> ❗ Use an isolated VLAN or lab network

---

### 💣 DATA LOSS

Autoinstall configs will:

* **wipe `/dev/sda` بالكامل**
* destroy ALL data on target machines

---

### 🔐 SECURITY RISKS

Default config includes:

* SSH password login enabled
* NFS exported to `*`
* Hardcoded credentials (in preseed)

> ⚠️ You MUST review configs before production use

---

# 🧱 Architecture

```
PXE Client
   ↓
dnsmasq (DHCP + TFTP)
   ↓
Bootloader (PXELINUX / GRUB)
   ↓
Kernel + initrd (TFTP)
   ↓
Root FS via NFS
   ↓
Autoinstall via HTTP (Apache)
```

---

# 📋 Requirements

* Ubuntu 22.04+ (server or desktop)
* Root / sudo access
* Internet access (for ISO download)
* Dedicated network (recommended)

---

# ⚙️ Quick Start

```bash
git clone <your-repo>
cd <repo>

chmod +x unifi-pxe-setup.sh
sudo ./unifi-pxe-setup.sh
```

### Fast update mode

```bash
sudo ./unifi-pxe-setup.sh --update
```

---

# 🌐 Network Configuration (AUTO-DETECTED)

The script automatically detects:

```bash
INTERFACE   = default route interface
SERVER_IP   = host IP
GATEWAY     = default gateway
DHCP_RANGE  = x.x.x.80 → x.x.x.100
```

### ✅ You MUST verify:

* Correct interface
* No DHCP conflicts
* مناسب subnet

---

# 📁 Directory Structure

```
/var/www/html/
├── iso_images/        # downloaded ISOs
├── ubuntu/            # extracted ISO contents (NFS root)
└── auto-install/
    ├── desktop/
    └── server/

/tftp/
├── bios/
├── efi/
└── grub/
```

---

# 💿 ISO Management

### Default ISOs

Edit inside script:

```bash
ISO_URLS=( ...)
```

### Or manually add ISOs:

```
/var/www/html/iso_images/
```

Script will:

* validate
* mount
* extract
* auto-create boot entries

---

# 🧠 Autoinstall Configuration (MOST IMPORTANT)

Location:

```
/var/www/html/auto-install/
```

---

## 🖥️ Desktop Config

### BIOS

```
desktop/user-data-bios
```

### UEFI

```
desktop/user-data-uefi
```

### Key fields to edit:

```yaml
identity:
  hostname: newsystem
  username: ubuntu
  password: <HASH>

locale: en_GB.UTF-8
timezone: Europe/London
keyboard:
  layout: gb
```

---

## 🖧 Server Config

```
server/user-data-bios
server/user-data-uefi
```

### Default installs GUI ⚠️

Remove if unwanted:

```yaml
- ubuntu-desktop-minimal
- xserver-xorg
```

---

# 🔐 Password Configuration

Passwords must be hashed:

```bash
mkpasswd -m sha-512
```

Example:

```yaml
password: '$6$hashed...'
```

---

# 🧾 Preseed (Ubuntu 22.04 Desktop Only)

Used for legacy installer (Ubiquity):

```
desktop/preseed-bios.cfg
desktop/preseed-uefi.cfg
```

### ⚠️ MUST EDIT

#### Credentials

```
username: ubuntu
password: ubuntu12*&
```

#### SMB mount (custom!)

```bash
//10.10.67.7/data
```

Update:

* IP
* username/password
* path

---

# 📡 dnsmasq Configuration

File:

```
/etc/dnsmasq.conf
```

### Key settings:

```ini
dhcp-range=START,END,12h
dhcp-option=3,GATEWAY
dhcp-option=6=DNS
enable-tftp
tftp-root=/tftp
```

---

# 📦 NFS Configuration

File:

```
/etc/exports
```

Default:

```
*(ro,sync,no_root_squash,...)
```

### 🔒 Recommended:

```
192.168.1.0/24(ro,...)
```

---

# 🖥️ PXE Boot Menu

### BIOS

```
/tftp/bios/pxelinux.cfg/default
```

### UEFI

```
/tftp/grub/grub.cfg
```

Each ISO generates:

* ✅ AUTO INSTALL
* 🔧 Manual install

---

# ▶️ Boot Parameters

### NFS Root

```
nfsroot=<SERVER_IP>:/var/www/html/ubuntu/<distro>
```

### Autoinstall source

```
http://<SERVER_IP>/auto-install/<type>/
```

---

# 🔄 Services

Managed automatically:

```bash
systemctl restart dnsmasq
systemctl restart apache2
systemctl restart nfs-kernel-server
```

---

# 🧪 Testing

1. Boot client machine
2. Select **PXE / Network Boot**
3. Choose:

   * AUTO INSTALL
   * Manual

---

# 🛠️ Troubleshooting

### View DHCP logs

```bash
journalctl -u dnsmasq -f
```

### Check web access

```bash
curl http://<SERVER_IP>/auto-install/
```

### Check NFS

```bash
showmount -e <SERVER_IP>
```

---

# 🔧 Customization Ideas

* Add more distros (Debian, Rocky, etc.)
* Integrate with VLAN provisioning
* Dynamic host-based configs
* Secure with HTTPS + restricted NFS

---

# 📌 Notes

* Works on both **server & desktop Ubuntu**
* Supports **multiple ISO versions simultaneously**
* Safe to re-run (idempotent-ish)

---

# 🙌 Credits

Built for automated lab provisioning, rapid deployment, and zero-touch installs.

---

# 📬 Contributing

PRs welcome — especially for:

* more distro support
* security improvements
* better config modularity

---
