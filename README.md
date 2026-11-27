## Modular Debian & Ubuntu Live ISO Builder

A modular build system (build.sh and install.sh) for creating custom, bootable Live ISO images supporting both UEFI and Legacy BIOS boot modes, multiple desktop environments, persistent storage, and automated hardware/network configuration. Designed around Debian Bookworm and Ubuntu Jammy (22.04 LTS), it is built for easy customization, clean layering, and automated release workflows.

### Key Features
Modular Layer Architecture: Builds cleanly in discrete stages—prep, base, dev, xorg, gui, and boot—so you can iterate quickly and customize individual layers without rebuilding everything from scratch.

Multi-Distro & Multi-Desktop Support: Defaults to Debian Bookworm with XFCE and MATE, while supporting TARGET_VERSION (such as jammy) and GUI_DESKTOPS selection across mate, kde, xfce, lxqt, lxde, and cinnamon.

Built-In Persistence: Supports persistent changes out of the box via a partition labeled ldata and persistence.conf (/ union,source=_debian/changes).

Live Environment Polish: Pre-configures NetworkManager interface management, DHCP/Wi-Fi tooling, MATE desktop/applet/GVFS integration, and block device handling for a smoother live session.

Hard Drive Installation: Includes install.sh to deploy the live environment onto a pre-partitioned drive after booting.

Automation-Ready: Structured to work smoothly with scripted builds and GitHub Actions release pipelines.

### Quick Usage

```bash
sudo ./build.sh all
```
Or
```bash
# 1. Install build dependencies
sudo ./build.sh prep
# 2. Build modular layers
sudo ./build.sh base
sudo ./build.sh dev
sudo ./build.sh xorg
sudo ./build.sh gui
# 3. Generate hybrid UEFI/Legacy ISO
sudo ./build.sh boot
```
### Build Result (Defaults to Debian Bookworm)
Final output: An ISO file supporting both UEFI and legacy boot methods.
    target/debian-bookworm-modular.iso

### To target another release or desktop selection:
Pass the TARGET_VERSION environment variable to build.sh:
```bash
sudo TARGET_VERSION=jammy GUI_DESKTOPS="mate lxqt" ./build.sh all
```

### Installation to Hard Drive
After booting from the Live ISO, you can run sudo ./install.sh to install it to your hard drive (requires pre-partitioning).

### System Data Persistence
Persistence data is stored by default on the hard drive partition labeled ldata.

persistence.conf
```conf
/   union,source=_debian/changes
```

## License
The build scripts and configuration files in this repository are licensed under the [MIT License](LICENSE).
