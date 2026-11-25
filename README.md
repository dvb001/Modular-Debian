## Modular Debian/Ubuntu Build Script

Base + devtools + xorg + desktop (mate|kde|xfce|lxqt|lxde|cinnamon)

### Build Steps

```bash
sudo ./build.sh all
```
Or
```bash
# Install required tool packages
sudo ./build.sh prep
# Generate base module
sudo ./build.sh base
# Generate developer tools module
sudo ./build.sh dev
# Generate desktop base module
sudo ./build.sh xorg
# Generate desktop
sudo ./build.sh gui
# Create ISO
sudo ./build.sh boot
```
### Build Result (Defaults to Debian Bookworm)
Final output: An ISO file supporting both UEFI and legacy boot methods.
    target/debian-bookworm-modular.iso

### Build Other OS Versions
Pass the TARGET_VERSION environment variable to build.sh:
```bash
sudo TARGET_VERSION=bookworm ./build.sh all
```
The default desktops are XFCE and MATE. For other desktops, use the GUI_DESKTOPS environment variable:
```bash
sudo TARGET_VERSION=bookworm GUI_DESKTOPS="mate xfce" ./build.sh all
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
