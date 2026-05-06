# 🚀 (Dynamic) UniFi PXE Ubuntu Deployment (BIOS + UEFI)

Fully automated PXE deployment environment for Ubuntu (Desktop & Server), supporting:

* ✅ Legacy BIOS (PXELINUX)
* ✅ UEFI (GRUB EFI)
* ✅ Multi-version Ubuntu (22.04 → 24.04 → future-ready)
* ✅ Automated installs (Subiquity + Preseed fallback)
* ✅ Dynamic PXE menu generation

---

## 📌 Overview

This project provides a **single Bash script** that transforms a fresh Ubuntu machine into a complete PXE deployment server.

It automates:

* ISO download & validation
* Extraction + NFS export
* PXE boot configuration (BIOS + UEFI)
* DHCP + TFTP via `dnsmasq`
* Autoinstall configuration via cloud-init
* Dynamic menu generation (AUTO + MANUAL installs)

---

## 🧭 PXE Boot Flow

```
PXE Client
    │
    ├── DHCP Request
    ▼
dnsmasq (DHCP + PXE)
    │
    ├── Boot File Provided
    │     ├── BIOS → pxelinux.0
    │     └── UEFI → bootx64.efi
    ▼
TFTP Server (/tftp)
    │
    ├── Bootloader Config (PXELINUX / GRUB)
    ▼
PXE Menu
    │
    ├── Load Kernel + Initrd
    ▼
NFS Server (/var/www/html/ubuntu)
    │
    ├── Root filesystem mount
    ▼
Apache (HTTP)
    │
    └── Autoinstall config (cloud-init / preseed)
```

---

## 🧱 Architecture

| Component | Purpose                     | Path                   |
| --------- | --------------------------- | ---------------------- |
| dnsmasq   | DHCP + PXE + TFTP           | `/etc/dnsmasq.conf`    |
| TFTP      | Bootloaders + kernel/initrd | `/tftp`                |
| Apache    | Autoinstall configs         | `/var/www/html`        |
| NFS       | OS filesystem delivery      | `/var/www/html/ubuntu` |

---

## 📂 Directory Structure

```
/var/www/html/
├── iso_images/
├── ubuntu/
│   ├── desktop.22.04/
│   ├── server.22.04/
│   └── ...
└── auto-install/
    ├── desktop/
    └── server/

/tftp/
├── bios/
├── efi/boot/
└── grub/
```

---

## ⚡ Features

* 🔄 **Dynamic ISO handling** (auto-detect version/type)
* 🧠 **Auto-generated PXE menus**
* 🖥️ **BIOS + UEFI support (single config)**
* 📦 **NFS-based root filesystem (fast + reliable)**
* 🤖 **Fully unattended installs**
* 🔧 **Reusable & customizable**

---

## 🛠️ Quick Start

```bash
git clone <your-repo>
cd <your-repo>

chmod +x unifi-pxe-setup.sh
sudo ./unifi-pxe-setup.sh
```

Optional fast mode (skip service restart):

```bash
sudo ./unifi-pxe-setup.sh --no-restart
```

---

## 🧪 Requirements

* Ubuntu host (server or desktop)
* Root / sudo access
* PXE-capable network
* No conflicting DHCP server on the network

---

## 🛠️ Manual Provisioning (Summary)

To replicate this setup manually, you would need to:

1. Install services (`dnsmasq`, `apache2`, `nfs-kernel-server`)
2. Configure DHCP + PXE boot options
3. Prepare TFTP bootloaders (BIOS + UEFI)
4. Download and extract Ubuntu ISOs
5. Export filesystems via NFS
6. Copy kernel + initrd into TFTP
7. Create PXE menus (PXELINUX + GRUB)
8. Configure cloud-init / preseed autoinstall
9. Start and verify services

➡️ This script automates all of the above.

[Step by step details Manual provisioning here.](Manually-setup-steps-no-scripts.md)


---

## 🤖 Autoinstall Support

### Subiquity (Modern Ubuntu)

* Cloud-init (`user-data`)
* Fully automated install
* Desktop + Server support

### Ubiquity (Ubuntu 22.04 Desktop)

* Preseed fallback
* Handles legacy installer edge cases

---

## 🔐 Customisation

You can modify:

* ISO sources
* DHCP range
* Autoinstall configs:

  * `/var/www/html/auto-install/`
* Package selection
* User credentials
* Post-install scripts

---

## ⚠️ Notes

* Default credentials are hardcoded → **change before production use**
* Ensure only one DHCP server is active
* UFW is disabled by the script

---

## 🧪 Troubleshooting

**PXE menu not appearing**

* Another DHCP server may be interfering

**Autoinstall not triggering**

```bash
curl http://<server-ip>/auto-install/desktop/user-data
```

**NFS issues**

```bash
exportfs -v
```

**Boot hangs**

* Check `nfsroot` path in PXE config

---

## 💡 Why Use This?

Manual PXE setup requires coordinating:

* DHCP
* TFTP
* NFS
* HTTP
* Bootloaders (BIOS + UEFI)
* Multiple Ubuntu installers

This script reduces all of that to:

```bash
sudo ./unifi-pxe-setup.sh
```

---

## 📦 Final

This is a **dynamic, reusable PXE deployment solution**.

👉 Download, modify, and adapt it to your environment.

---

## 📜 License

MIT

---

## 🙌 Contributions

PRs, improvements, and ideas welcome.
