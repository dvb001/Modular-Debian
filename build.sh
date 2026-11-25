#!/bin/bash
# ==========================================================
# Debian 12 Modular Live System Build Script
# Module structure:
#   - 001-base.squashfs			: Base system + core kernel + debian user
#   - 002-devtools.squashfs		: Python / Go / Rust / toolchain
#   - 003-xorg.squashfs			: Desktop base packages xserver / lightdm shared packages
#   - 004-gui.squashfs			: Optional desktop environments such as Xfce and Mate
# ==========================================================

# Default desktop
SET_DESKTOPS="${GUI_DESKTOPS:-mate xfce}"
# Default version
TARGET_VERSION="$(echo "${TARGET_VERSION:-bookworm}" | tr '[:upper:]' '[:lower:]')"
# Overlay mount command
MOUNT_OVERLAY_CMD="fuse-overlayfs"

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[−] Please run this script with sudo or root privileges."
  exit 1
fi

# 2. Determine whether Ubuntu or Debian should be used based on the codename
case "$TARGET_VERSION" in
    # Ubuntu codenames
    bionic|focal|jammy|mantic|noble|oracular)
        TARGET_OS="ubuntu"
        MIRROR_URL="http://archive.ubuntu.com/ubuntu/"
        SECURITY_URL="http://security.ubuntu.com/ubuntu/"
        COMPONENTS="main restricted universe multiverse"
		KERNEL_PKG="linux-image-generic"
		HEADERS_PKG="linux-headers-generic"
		XORG_PKG="firefox pluma"
        ;;
        
    # Debian and unknown codenames
    *)
        TARGET_OS="debian"
        MIRROR_URL="http://deb.debian.org/debian"
        SECURITY_URL="http://deb.debian.org/debian-security"
        COMPONENTS="main contrib non-free non-free-firmware"
		KERNEL_PKG="linux-image-amd64"
		HEADERS_PKG="linux-headers-amd64"
		XORG_PKG="firefox-esr pluma pluma-plugins"
        ;;
esac

WORK_DIR="$PWD/target"
BASE_ROOT="$WORK_DIR/001-base"
DEV_ROOT="$WORK_DIR/002-dev"
XORG_ROOT="$WORK_DIR/003-xorg"
GUI_ROOT="$WORK_DIR/004-gui"
OTHER_ROOT="$WORK_DIR/005-other"

BASE_CHROOT="$BASE_ROOT/chroot"
DEV_CHROOT="$DEV_ROOT/chroot"
XORG_CHROOT="$XORG_ROOT/chroot"
GUI_CHROOT="$GUI_ROOT/chroot"
OTHER_CHROOT="$TOOLS_ROOT/chroot"

DEV_STAGE="$DEV_ROOT/stage"
XORG_STAGE="$XORG_ROOT/stage"
GUI_STAGE="$GUI_ROOT/stage"
OTHER_STAGE="$TOOLS_ROOT/stage"

DEV_WORK="$DEV_ROOT/work"
XORG_WORK="$XORG_ROOT/work"
GUI_WORK="$GUI_ROOT/work"
OTHER_WORK="$TOOLS_ROOT/work"

ISO_DIR="$WORK_DIR/iso"
OUTPUT_ISO="$WORK_DIR/$TARGET_OS-$TARGET_VERSION-modular.iso"

mount_chroot() {
    mount -t proc proc "$1/proc"
    mount -t sysfs sysfs "$1/sys"
    mount --bind /dev "$1/dev"
    mount --bind /dev/pts "$1/dev/pts"
}

umount_chroot() {
    umount "$1/proc" || true
    umount "$1/sys" || true
    umount "$1/dev/pts" || true
    umount "$1/dev" || true
    umount "$1" 2>/dev/null || true
}

cp_initramfs() {
    echo "$1"
    for file in "$1/boot/"initrd.img-*; do
        # Ensure that the file actually exists
        if [ -f "$file" ]; then
            echo "Copying initramfs to ISO..."
            cp -v "$file" "$ISO_DIR/boot/initrd.img"
            rm "$file"
        fi
    done
}

step_prep() {
    echo "[+] Install basic packages..."
    apt-get update
    apt-get install -y debootstrap squashfs-tools initramfs-tools \
	    isolinux dosfstools syslinux-utils xorriso rsync \
	    grub-pc-bin grub-efi-amd64-bin
}

rm_stage_temps() {
    rm -f "$1/etc/passwd" "$1/etc/shadow" "$1/etc/group" \
          "$1/etc/gshadow" "$1/etc/machine-id" "$1/etc/hostname" \
          "$1/etc/hosts"
}

step_base() {
	echo "Target version: $TARGET_VERSION"
	sleep 1
    echo "[+] Step 1/5: Building the base system (001-base)..."
    
    mkdir -p "$BASE_CHROOT" "$ISO_DIR/live" "$ISO_DIR/boot" "$ISO_DIR/isolinux"

    if [ ! -f "$BASE_CHROOT/bin/bash" ]; then
        debootstrap --arch=amd64 "$TARGET_VERSION" "$BASE_CHROOT" "$MIRROR_URL"
    fi

	# 3. Write sources.list
	cat <<EOF > "$BASE_CHROOT/etc/apt/sources.list"
deb $MIRROR_URL $TARGET_VERSION $COMPONENTS
deb $MIRROR_URL $TARGET_VERSION-updates $COMPONENTS
deb $SECURITY_URL $TARGET_VERSION-security $COMPONENTS
EOF

    echo "[*] Installing the kernel and base services in Base, and creating the debian user..."
    umount_chroot "$BASE_CHROOT" || true
    mount_chroot "$BASE_CHROOT"

    chroot "$BASE_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && \
		apt-get upgrade -y && \
        apt-get install -y $KERNEL_PKG live-boot initramfs-tools \
			fuse3 ntfs-3g squashfs-tools \
			systemd-sysv network-manager sudo && \
        echo 'debian' > /etc/hostname && \
        grep -q '127.0.0.1.*debian' /etc/hosts || echo '127.0.0.1   debian' >> /etc/hosts && \
        id debian &>/dev/null || useradd -m -s /bin/bash debian && \
        echo 'debian:toor' | chpasswd && \
        usermod -aG sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev debian && \
        apt-get clean
    "

    patch_block_mount() {
        echo "[*] Patching base..."
        cp -R ./data/patch/* "$BASE_CHROOT/"
        chroot "$BASE_CHROOT" /bin/bash -c '
		    KERNEL_VERSION=$(ls /lib/modules 2>/dev/null | head -n 1 | tr -d "[:space:]")
		    if [ -z "$KERNEL_VERSION" ]; then
		        KERNEL_VERSION="all"
		    fi    
		    echo "[*] Detected target kernel version: $KERNEL_VERSION"
		    if [ -f "/usr/sbin/update-initramfs.orig.initramfs-tools" ]; then
		        update-initramfs.orig.initramfs-tools -u -k "$KERNEL_VERSION"
		    else
		        update-initramfs -u -k "$KERNEL_VERSION"
		    fi
		    systemctl enable fix-dpkg-status.service
		'
    }
    patch_block_mount || true

    cp_initramfs "$BASE_CHROOT"

    umount_chroot "$BASE_CHROOT" || true
    echo "[*] Packaging 001-base.squashfs..."
    rm "$ISO_DIR/live/001-base.squashfs" 2>/dev/null || true
    mksquashfs "$BASE_CHROOT" "$ISO_DIR/live/001-base.squashfs" -comp xz
    echo "[+] 001-base build complete!"
}

step_dev() {
    echo "[+] Step 2/5: Building the DevTools incremental module (002-devtools)..."

    # Create required directories and working directories
    umount_chroot "$DEV_CHROOT"
    read -p "Remove last stage? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Removing previous records..."
        rm -rf "$DEV_ROOT"
    fi
    mkdir -p "$DEV_CHROOT" "$DEV_STAGE" "$DEV_WORK"

    echo "[*] Mounting overlay system..."
    # Mount overlay
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$BASE_CHROOT",upperdir="$DEV_STAGE",workdir="$DEV_WORK" \
        "$DEV_CHROOT"
    mount_chroot "$DEV_CHROOT"

    echo "[*] Obtaining kernel version from the base system..."
    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[−] Error: Please build the base module first (step_prep); no kernel was found in Base!"
        exit 1
    fi
    KERNEL_VERSION=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[+] Detected target kernel version: $KERNEL_VERSION"

    echo "[*] Installing the development toolchain in the Dev Chroot..."
    chroot "$DEV_CHROOT" /bin/bash -c '
	    export DEBIAN_FRONTEND=noninteractive
	    apt-get install -y --no-install-recommends \
	        build-essential git curl wget vim htop cmake pkg-config \
	        '"$HEADERS_PKG"' unzip gawk gpg \
	        python3 python3-pip python3-venv golang rustc cargo || true
	
	    # Automatically detect the kernel or system header suffix
	    if echo "'"$KERNEL_VERSION"'" | grep -q "generic"; then
	        HEADER_SUFFIX="generic"
	    else
	        HEADER_SUFFIX="amd64"
	    fi
	
	    echo "[*] Creating symbolic links for the target kernel version: '"$KERNEL_VERSION"' (suffix: $HEADER_SUFFIX)"
	
	    INSTALLED_HEADER=$(ls -d /usr/src/linux-headers-*-$HEADER_SUFFIX 2>/dev/null | head -n 1)
	    INSTALLED_COMMON=$(ls -d /usr/src/linux-headers-*-common 2>/dev/null | head -n 1)
	
	    if [ -n "$INSTALLED_HEADER" ]; then
	        TARGET_HEADER_DIR="/usr/src/linux-headers-'"$KERNEL_VERSION"'"
	        if [ ! -e "$TARGET_HEADER_DIR" ]; then
	            ln -sfn "$INSTALLED_HEADER" "$TARGET_HEADER_DIR"
	            echo "[+] Created header architecture directory symbolic link: $TARGET_HEADER_DIR -> $INSTALLED_HEADER"
	        fi
	    fi
	
	    if [ -n "$INSTALLED_COMMON" ]; then
	        BASE_VER=$(echo "'"$KERNEL_VERSION"'" | sed "s/-$HEADER_SUFFIX//")
	        TARGET_COMMON_DIR="/usr/src/linux-headers-$BASE_VER-common"
	        if [ ! -e "$TARGET_COMMON_DIR" ]; then
	            ln -sfn "$INSTALLED_COMMON" "$TARGET_COMMON_DIR"
	            echo "[+] Created common header directory symbolic link: $TARGET_COMMON_DIR -> $INSTALLED_COMMON"
	        fi
	    fi
	
	    MODULE_DIR="/lib/modules/'"$KERNEL_VERSION"'"
	    mkdir -p "$MODULE_DIR"
	    if [ -d "/usr/src/linux-headers-'"$KERNEL_VERSION"'" ]; then
	        ln -sfn "/usr/src/linux-headers-'"$KERNEL_VERSION"'" "$MODULE_DIR/build"
	        echo "[+] Bound symbolic link /lib/modules/'"$KERNEL_VERSION"'/build"
	    elif [ -n "$INSTALLED_HEADER" ]; then
	        ln -sfn "$INSTALLED_HEADER" "$MODULE_DIR/build"
	        echo "[+] Bound /lib/modules/'"$KERNEL_VERSION"'/build symbolic link to the actual directory"
	    fi
	
	    echo "[+] Symbolic link setup complete!"
	    apt-get clean
	'

    sleep 2
    umount_chroot "$DEV_CHROOT"
    #rm_stage_temps "$DEV_STAGE"
    
    echo "[*] Packaging 002-devtools.squashfs..."
    rm "$ISO_DIR/live/002-devtools.squashfs" 2>/dev/null || true
    mksquashfs "$DEV_STAGE" "$ISO_DIR/live/002-devtools.squashfs" -comp xz
    echo "[+] 002-devtools incremental module build complete!"
}

step_xorg() {
    echo "[+] Step 3/5: Building the Xorg desktop environment module (003-xorg)..."

    echo "[*] Mounting overlay system..."
    umount "$XORG_CHROOT" || true
    read -p "Remove last stage? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Removing previous records..."
        rm -rf "$XORG_ROOT"
    fi
    mkdir -p "$XORG_CHROOT" "$XORG_STAGE" "$XORG_WORK"

    # Mount overlay
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$DEV_STAGE:$BASE_CHROOT",upperdir="$XORG_STAGE",workdir="$XORG_WORK" \
        "$XORG_CHROOT"
	mount_chroot "$XORG_CHROOT"

    echo "[*] Installing Xorg and related software in the Xorg Chroot..."
    chroot "$XORG_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y --no-install-recommends \
            lightdm lightdm-gtk-greeter \
            xserver-xorg xserver-xorg-core \
            xinit x11-xserver-utils im-config \
            libnotify-bin desktop-base \
            fcitx5 fcitx5-config-qt fcitx5-chinese-addons \
            fcitx5-frontend-qt5 fcitx-frontend-gtk3 \
            engrampa gnome-terminal \
            font-viewer libwebkit2gtk-4.1-0 \
            gvfs-backends gvfs-fuse caja \
            pulseaudio pavucontrol \
            $XORG_PKG \
            gparted mesa-utils network-manager-gnome && \
        apt-get clean
    "

	# Fix Ubuntu networking
	if [ "$TARGET_OS" == "ubuntu" ]; then
		chroot "$XORG_CHROOT" /bin/bash -c '
		    # Ensure the NetworkManager configuration directory exists
		    mkdir -p /etc/NetworkManager/conf.d
		
		    # Write a global takeover configuration to resolve cards showing as unmanaged
		    cat << '\''EOF'\'' > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf
[keyfile]
unmanaged-devices=none
EOF
		    # Enable NetworkManager service at boot
		    systemctl enable NetworkManager
		'
	fi

    sleep 2
    umount "$XORG_CHROOT" || true
    
    cp_initramfs "$XORG_STAGE"

    echo "[*] Packaging 003-xorg.squashfs..."
    rm "$ISO_DIR/live/003-xorg.squashfs" 2>/dev/null || true
    mksquashfs "$XORG_STAGE" "$ISO_DIR/live/003-xorg.squashfs" -comp xz
    echo "[+] 003-xorg incremental module build complete!"
}

step_gui() {
    # Default to Mate when no arguments are provided
    if [ $# -eq 0 ]; then
        set -- mate
    fi
    
    local pkg_list=""
    local desktop_desc=""
    
    # Traverse all desktop type arguments
    for desktop_type in "$@"; do
        case "$desktop_type" in
            mate)
                pkg_list="$pkg_list mate-desktop-environment-core eom mate-applets mate-indicator-applet mate-applet-brisk-menu ayatana-indicator-application"
                ;;
            xfce)
                pkg_list="$pkg_list xfce4 xfce4-goodies"
                ;;
            lxqt)
                pkg_list="$pkg_list lxqt lxqt-themes breeze-gtk-theme breeze-icon-theme"
                ;;
            kde)
                pkg_list="$pkg_list kde-plasma-desktop"
                ;;
            lxde)
                pkg_list="$pkg_list lxde"
                ;;
            cinnamon)
                pkg_list="$pkg_list cinnamon cinnamon-control-center"
                ;;
            *)
                echo "[−] Error: Unknown desktop type '$desktop_type' (supported: mate, xfce, lxqt, kde, lxde, cinnamon)"
                return 1
                ;;
        esac
        desktop_desc="${desktop_desc} ${desktop_type}"
    done

    local module_name="004-gui.squashfs"
    local multi_chroot="${GUI_CHROOT}"
    local multi_stage="${GUI_STAGE}"
    local multi_work="${GUI_WORK}"

    echo "[+] Step: Building the unified GUI desktop module (including:${desktop_desc})..."
    echo "[*] Package list: $pkg_list"

    echo "[*] Mounting overlay system..."
    umount_chroot "$multi_chroot" || true
    read -p "Remove last stage for gui? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Removing previous records..."
        rm -rf "$GUI_ROOT"
    fi
    mkdir -p "$multi_chroot" "$multi_stage" "$multi_work"

    # Mount overlay
    $MOUNT_OVERLAY_CMD \
        -o lowerdir="$XORG_STAGE:$DEV_STAGE:$BASE_CHROOT",upperdir="$multi_stage",workdir="$multi_work" \
        "$multi_chroot"
    mount_chroot "$multi_chroot"

    echo "[*] Installing the selected desktop and related software in the GUI Chroot..."
    chroot "$multi_chroot" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && \
        apt-get install -y --no-install-recommends \
            $pkg_list \
            && \
        apt-get clean
    "
    sleep 2
    umount_chroot "$multi_chroot" || true
    
    echo "[*] Packaging $module_name..."
    rm "$ISO_DIR/live/$module_name" 2>/dev/null || true
    mksquashfs "$multi_stage" "$ISO_DIR/live/$module_name" -comp xz
    echo "[+] Unified GUI module ($module_name) build complete!"
}

make_uefi_boot() {
    # 1. Create a 32 MB blank FAT image
    mkdir -p "$ISO_DIR/boot/grub"
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efiboot.img" bs=1M count=32
    mkfs.vfat "$ISO_DIR/boot/grub/efiboot.img"

    # 2. Mount the image
    mkdir -p /tmp/efi_install
    mount -o loop "$ISO_DIR/boot/grub/efiboot.img" /tmp/efi_install

    # 3. Use the host GRUB installation to install GRUB directly
    grub-install --target=x86_64-efi \
                --efi-directory=/tmp/efi_install \
                --boot-directory=/tmp/efi_install/boot \
                --removable \
                --no-floppy \
                --modules="normal part_gpt part_msdos fat search iso9660 linux"

    umount /tmp/efi_install
    rm -rf /tmp/efi_install

    cat << 'EOF' > "$ISO_DIR/boot/grub/grub.cfg"
set timeout=50
set default=0

menuentry "Start $TARGET_OS $TARGET_VERSION Modular (UEFI)" {
    search --no-floppy --set=root --file /boot/vmlinuz
    linux /boot/vmlinuz boot=live components splash
    initrd /boot/initrd.img
}

menuentry "Start $TARGET_OS $TARGET_VERSION Modular (persistence) (UEFI)" {
    search --no-floppy --set=root --file /boot/vmlinuz
    linux /boot/vmlinuz boot=live persistence persistence-label=ldata components splash
    initrd /boot/initrd.img
}
EOF
}

make_iso_boot() {
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/"

    cat <<EOF > "$ISO_DIR/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50

LABEL system-modular
    MENU LABEL Start $TARGET_OS $TARGET_VERSION Modular
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live components splash
LABEL system-modular-with-persistence
    MENU LABEL Start $TARGET_OS $TARGET_VERSION Modular (persistence) 
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live persistence persistence-label=ldata components splash
EOF
}

step_boot() {
    echo "[+] ISO: Extracting kernel, configuring boot, and generating a hybrid ISO (BIOS + UEFI)..."

    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[−] Error: Could not find a kernel in $BASE_CHROOT/boot!"
        exit 1
    fi
    
    KERNEL_VER=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[*] Detected kernel version: $KERNEL_VER"

    [ -f ./data/install.sh ] && cp ./data/install.sh "$ISO_DIR/"
    cp "$BASE_CHROOT/boot/vmlinuz-$KERNEL_VER" "$ISO_DIR/boot/vmlinuz"

    make_uefi_boot
    make_iso_boot
    
    echo "[*] Generating a hybrid ISO with BIOS and UEFI support: $OUTPUT_ISO"
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "DEBIAN_MODULAR" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -output "$OUTPUT_ISO" \
        "$ISO_DIR"

    echo "[+] Success! Hybrid ISO image path: $OUTPUT_ISO"
}

case "${1:-}" in
    prep)
        step_prep
        ;;
    base)
        step_base
        ;;
    xorg)
        step_xorg
        ;;
    dev)
        step_dev
        ;;
    gui)
        step_gui $SET_DESKTOPS
        ;;
    boot)
        step_boot
        ;;
    all)
        step_prep
        step_base
        step_dev
        step_xorg
        step_gui $SET_DESKTOPS
        step_boot
        ;;
    *)
        echo "Usage: $0 {prep|xorg|dev|gui|boot|all}"
        exit 1
        ;;
esac
