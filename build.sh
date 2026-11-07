#!/bin/bash
# ==========================================================
# Debian 12 多模块 Live 系统构建脚本 (带 Apt 记录继承与排重机制)
# 模块结构:
#   - 001-base.squashfs    : 基础系统 + 核心内核 + 用户(debian)
#   - 002-mate.squashfs    : MATE 桌面 + LightDM + 完整 Apt 记录 (增量)
#   - 003-devtools.squashfs: Python / Go / Rust / 工具链 + 完整 Apt 记录 (增量)
# ==========================================================

set -e

if [ "$EUID" -ne 0 ]; then
  echo "[-] 请使用 sudo 或 root 权限运行此脚本。"
  exit 1
fi

WORK_DIR="$PWD/target"
BASE_CHROOT="$WORK_DIR/001-base-chroot"
DEV_CHROOT="$WORK_DIR/002-dev-chroot"
XORG_CHROOT="$WORK_DIR/003-xorg-chroot"
GUI_CHROOT="$WORK_DIR/004-gui-chroot"

DEV_STAGE="$WORK_DIR/002-dev-stage"
XORG_STAGE="$WORK_DIR/003-xorg-stage"
GUI_STAGE="$WORK_DIR/004-gui-stage"

DEV_WORK="$WORK_DIR/002-dev-work"
XORG_WORK="$WORK_DIR/003-xorg-work"
GUI_WORK="$WORK_DIR/004-gui-work"

ISO_DIR="$WORK_DIR/iso"
OUTPUT_ISO="$WORK_DIR/debian-12-modular.iso"

echo "[+] Install basic packages..."
apt update
apt install -y debootstrap squashfs-tools initramfs-tools \
    isolinux dosfstools syslinux-utils xorriso rsync \
    grub-pc-bin grub-efi-amd64-bin

rm_stage_temps() {
    rm -f "$1/etc/passwd" "$1/etc/shadow" "$1/etc/group" \
          "$1/etc/gshadow" "$1/etc/machine-id" "$1/etc/hostname" \
          "$1/etc/hosts"
}

step_prep() {
    echo "[+] 步骤 1/5: 构建基础系统 (001-base)..."
    
    mkdir -p "$BASE_CHROOT" "$ISO_DIR/live" "$ISO_DIR/boot" "$ISO_DIR/isolinux"

    if [ ! -f "$BASE_CHROOT/bin/bash" ]; then
        debootstrap --arch=amd64 bookworm "$BASE_CHROOT" http://deb.debian.org/debian/
    fi

    cat <<EOF > "$BASE_CHROOT/etc/apt/sources.list"
deb http://mirrors.tuna.tsinghua.edu.cn/debian bookworm main contrib non-free non-free-firmware
deb http://mirrors.tuna.tsinghua.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

    echo "[*] 在 Base 中安装内核、基础服务并创建用户 debian..."
    chroot "$BASE_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y linux-image-amd64 live-boot initramfs-tools \
			fuse3 ntfs-3g squashfs-tools \
			systemd-sysv network-manager sudo && \
        echo 'debian' > /etc/hostname && \
        grep -q '127.0.0.1.*debian' /etc/hosts || echo '127.0.0.1   debian' >> /etc/hosts && \
        id debian &>/dev/null || useradd -m -s /bin/bash debian && \
        echo 'debian:toor' | chpasswd && \
        usermod -aG sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev debian && \
        apt clean
    "

    IMG_PATH="$BASE_CHROOT/boot/initrd.img-6.1.0-54-amd64"
    patch_block_mount() {
        echo "[*] 添加 Porteus 的磁盘挂载方式..."
        cp -R ./data/patch/* "$BASE_CHROOT/"
        chroot "$BASE_CHROOT" /bin/bash -c "
            update-initramfs -u -k all
        "
    }
    patch_block_mount || true

    cp "$IMG_PATH" "$ISO_DIR/boot/initrd.img"
    rm "$1/etc/ld.so.cache" || true

    echo "[*] 打包 001-base.squashfs..."
    rm "$ISO_DIR/live/001-base.squashfs" 2>/dev/null || true
    mksquashfs "$BASE_CHROOT" "$ISO_DIR/live/001-base.squashfs" -comp xz
    echo "[+] 001-base 构建完成！"
}

step_dev() {
    echo "[+] 步骤 2/5: 构建 DevTools 开发工具增量模块 (002-devtools)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mountting overlay systems..."
    umount "$DEV_CHROOT" 2>/dev/null || true
    read -p "Remove last stage? [y/N]" choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$DEV_CHROOT" "$DEV_STAGE" "$DEV_WORK"
    fi
    mkdir -p "$DEV_CHROOT" "$DEV_STAGE" "$DEV_WORK"

    # 使用 overlay 挂载
    mount -t overlay overlay \
        -o lowerdir="$BASE_CHROOT",upperdir="$DEV_STAGE",workdir="$DEV_WORK" \
        "$DEV_CHROOT"

    echo "[*] 正在从 Base 系统获取内核版本..."
    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[-] 错误: 请先构建 base 模块 (step_prep)，未在 Base 中找到内核！"
        exit 1
    fi
    KERNEL_VERSION=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[+] 检测到目标内核版本: $KERNEL_VERSION"

    echo "[*] 在 Dev Chroot 中安装开发工具链..."
    chroot "$DEV_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y --no-install-recommends \
            build-essential git curl wget vim htop cmake pkg-config \
            linux-headers-amd64 gawk gpg \
            python3 python3-pip python3-venv golang rustc cargo || true \

        echo '[*] 正在创建软链接以适配目标内核版本: $KERNEL_VERSION'

        INSTALLED_HEADER=\$(ls -d /usr/src/linux-headers-*-amd64 2>/dev/null | head -n 1)
        INSTALLED_COMMON=\$(ls -d /usr/src/linux-headers-*-common 2>/dev/null | head -n 1)

        if [ -n \"\$INSTALLED_HEADER\" ]; then
            TARGET_HEADER_DIR=\"/usr/src/linux-headers-$KERNEL_VERSION\"
            if [ ! -e \"\$TARGET_HEADER_DIR\" ]; then
                ln -sfn \"\$INSTALLED_HEADER\" \"\$TARGET_HEADER_DIR\"
                echo \"[+] 已创建头文件架构目录软链接: \$TARGET_HEADER_DIR -> \$INSTALLED_HEADER\"
            fi
        fi

        if [ -n \"\$INSTALLED_COMMON\" ]; then
            BASE_VER=\$(echo $KERNEL_VERSION | sed 's/-amd64//')
            TARGET_COMMON_DIR=\"/usr/src/linux-headers-\$BASE_VER-common\"
            if [ ! -e \"\$TARGET_COMMON_DIR\" ]; then
                ln -sfn \"\$INSTALLED_COMMON\" \"\$TARGET_COMMON_DIR\"
                echo \"[+] 已创建通用头文件目录软链接: \$TARGET_COMMON_DIR -> \$INSTALLED_COMMON\"
            fi
        fi

        MODULE_DIR=\"/lib/modules/$KERNEL_VERSION\"
        mkdir -p \"\$MODULE_DIR\"
        if [ -d \"/usr/src/linux-headers-$KERNEL_VERSION\" ]; then
            ln -sfn \"/usr/src/linux-headers-$KERNEL_VERSION\" \"\$MODULE_DIR/build\"
            echo '[+] 已绑定 /lib/modules/$KERNEL_VERSION/build 软链接'
        elif [ -n \"\$INSTALLED_HEADER\" ]; then
            ln -sfn \"\$INSTALLED_HEADER\" \"\$MODULE_DIR/build\"
            echo '[+] 已绑定 /lib/modules/$KERNEL_VERSION/build 软链接到实际目录'
        fi

        echo '[+] 软链接构建完成！'
        apt clean
    "
    sleep 2
    umount "$DEV_CHROOT" 2>/dev/null || true
    #rm_stage_temps "$DEV_STAGE"
    
    # 3. 打包排重后的增量模块
    echo "[*] 打包 002-devtools.squashfs..."
    rm "$ISO_DIR/live/002-devtools.squashfs" 2>/dev/null || true
    mksquashfs "$DEV_STAGE" "$ISO_DIR/live/002-devtools.squashfs" -comp xz
    echo "[+] 002-devtools 增量模块构建完成！"
}

step_xorg() {
    echo "[+] 步骤 3/5: 构建 XORG 桌面环境模块 (003-xorg)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mountting overlay systems..."
    umount "$XORG_CHROOT" 2>/dev/null || true
    read -p "Remove last stage? [y/N]" choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$XORG_CHROOT" "$XORG_STAGE" "$XORG_WORK"
    fi
    mkdir -p "$XORG_CHROOT" "$XORG_STAGE" "$XORG_WORK"

    # 使用 overlay 挂载
    mount -t overlay overlay \
        -o lowerdir="$DEV_CHROOT:$BASE_CHROOT",upperdir="$XORG_STAGE",workdir="$XORG_WORK" \
        "$XORG_CHROOT"

    echo "[*] 在 XORG Chroot 中安装 xorg 及相关软件..."
    chroot "$XORG_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y --no-install-recommends \
            lightdm xserver-xorg xserver-xorg-core \
            xinit x11-xserver-utils im-config \
            libnotify-bin desktop-base \
            fcitx5 fcitx5-config-qt fcitx5-chinese-addons \
            fcitx5-frontend-qt5 fcitx-frontend-gtk3 \
            pluma pluma-plugins engrampa gnome-terminal \
            gvfs-backends gvfs-fuse \
            firefox-esr \
            gparted mesa-utils network-manager-gnome && \
        apt clean
    "
    # fonts-noto-cjk fonts-noto-cjk-extra

    sleep 2
    umount "$XORG_CHROOT" || true
    
    # 3. 打包排重后的增量模块
    echo "[*] 打包 003-xorg.squashfs..."
    rm "$ISO_DIR/live/003-xorg.squashfs" 2>/dev/null || true
    mksquashfs "$XORG_STAGE" "$ISO_DIR/live/003-xorg.squashfs" -comp xz
    echo "[+] 003-xorg 增量模块构建完成！"
}

step_gui() {
    # 接收传入的桌面类型参数，默认使用 mate
    local desktop_type="${1:-mate}"
    
    # 根据传入的桌面类型映射对应的包名和模块文件名
    local pkg_list=""
    local module_name="004-$desktop_type.squashfs"
    case "$desktop_type" in
        mate)
            pkg_list="mate-desktop-environment-core"
            ;;
        xfce)
            pkg_list="xfce4 xfce4-goodies"
            ;;
        lxqt)
            pkg_list="lxqt lxqt-themes breeze-gtk-theme breeze-icon-theme"
            ;;
        kde)
            pkg_list="kde-plasma-desktop"
            ;;
        lxde)
            pkg_list="lxde"
            ;;
        cinnamon)
            pkg_list="cinnamon cinnamon-control-center"
            ;;
        *)
            echo "[-] 错误: 未知的桌面类型 '$desktop_type' (支持: mate, xfce, lxqt, kde, lxde, cinnamon)"
            return 1
            ;;
    esac

    echo "[+] 步骤: 构建 GUI 桌面环境模块 ($desktop_type)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mounting overlay systems..."
    umount "$GUI_CHROOT-$desktop_type" 2>/dev/null || true
    read -p "Remove last stage for $desktop_type? [y/N] " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "删除历史记录..."
        rm -rf "$GUI_CHROOT-$desktop_type" "$GUI_STAGE-$desktop_type" "$GUI_WORK-$desktop_type"
    fi
    mkdir -p "$GUI_CHROOT-$desktop_type" "$GUI_STAGE-$desktop_type" "$GUI_WORK-$desktop_type"

    # 使用 overlay 挂载
    mount -t overlay overlay \
        -o lowerdir="$XORG_STAGE:$DEV_STAGE:$BASE_CHROOT",upperdir="$GUI_STAGE-$desktop_type",workdir="$GUI_WORK-$desktop_type" \
        "$GUI_CHROOT-$desktop_type"

    echo "[*] 在 GUI Chroot 中安装 $desktop_type 桌面及相关软件..."
    chroot "$GUI_CHROOT-$desktop_type" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y --no-install-recommends \
            $pkg_list \
            && \
        apt clean
    "
    sleep 2
    umount "$GUI_CHROOT-$desktop_type" || true
    
    # 打包排重后的增量模块
    echo "[*] 打包 $module_name..."
    rm "$ISO_DIR/live/$module_name" 2>/dev/null || true
    mksquashfs "$GUI_STAGE-$desktop_type" "$ISO_DIR/live/$module_name" -comp xz
    echo "[+] $desktop_type 桌面增量模块 ($module_name) 构建完成！"
}

make_uefi_boot() {
    # 1. 创建一个 4MB 的空白 FAT 镜像
    mkdir -p "$ISO_DIR/boot/grub"
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efiboot.img" bs=1M count=32
    mkfs.vfat "$ISO_DIR/boot/grub/efiboot.img"

    # 2. 挂载镜像
    mkdir -p /tmp/efi_install
    mount -o loop "$ISO_DIR/boot/grub/efiboot.img" /tmp/efi_install

    # 3. 使用宿主机的 grub-install 直接将 GRUB 安装到这个挂载点中
    # 这样会自动生成 EFI/BOOT/BOOTX64.EFI 以及所需的全部核心模块
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

EOF
}

make_iso_boot() {
    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/"

    cat <<EOF > "$ISO_DIR/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT debian-modular-mate
EOF
}

step_boot() {
    echo "[+] 步骤 5/5: 提取内核、配置引导并生成双启动 ISO (BIOS + UEFI)..."

    KERNEL_FILE=$(find "$BASE_CHROOT/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
    if [ -z "$KERNEL_FILE" ]; then
        echo "[-] 错误: 未能在 $BASE_CHROOT/boot 中找到内核！"
        exit 1
    fi
    
    KERNEL_VER=$(basename "$KERNEL_FILE" | sed 's/vmlinuz-//')
    echo "[*] 检测到内核版本: $KERNEL_VER"

    [ -f ./data/install.sh ] && cp ./data/install.sh "$ISO_DIR/"
    cp "$BASE_CHROOT/boot/vmlinuz-$KERNEL_VER" "$ISO_DIR/boot/vmlinuz"
    cp "$BASE_CHROOT/boot/initrd.img-$KERNEL_VER" "$ISO_DIR/boot/initrd.img"

    make_uefi_boot
    make_iso_boot
    
    echo "[*] 正在生成支持 BIOS 与 UEFI 的混合 ISO 镜像: $OUTPUT_ISO"

    link_base() {
        if [ ! -f "$ISO_DIR/live/004-$1.squashfs" ]; then
            return
        fi
        rm -rf "$ISO_DIR/live-$1"
        mkdir -p "$ISO_DIR/live-$1"
        ln -f "$ISO_DIR/live/001-base.squashfs" "$ISO_DIR/live-$1/"
        ln -f "$ISO_DIR/live/002-devtools.squashfs" "$ISO_DIR/live-$1/"
        ln -f "$ISO_DIR/live/003-xorg.squashfs" "$ISO_DIR/live-$1/"
        ln -f "$ISO_DIR/live/004-$1.squashfs" "$ISO_DIR/live-$1/"

        echo "LABEL debian-modular-$1" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    MENU LABEL Start Debian 12 Modular $1" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    KERNEL /boot/vmlinuz" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    APPEND initrd=/boot/initrd.img boot=live live-media-path=live-$1 components splash" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "LABEL debian-modular-$1-with-persistence" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    MENU LABEL Start Debian 12 Modular $1 (persistence) " >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    KERNEL /boot/vmlinuz" >> "$ISO_DIR/isolinux/isolinux.cfg"
        echo "    APPEND initrd=/boot/initrd.img boot=live live-media-path=live-$1 persistence persistence-label=ldata components splash" >> "$ISO_DIR/isolinux/isolinux.cfg"

        echo "menuentry \"Start Debian 12 Modular $1 (UEFI)\" {" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    search --no-floppy --set=root --file /boot/vmlinuz" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    linux /boot/vmlinuz boot=live live-media-path=live-$1 components splash" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    initrd /boot/initrd.img" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "}" >> "$ISO_DIR/boot/grub/grub.cfg"

        echo "menuentry \"Start Debian 12 Modular $1 (persistence) (UEFI)\" {" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    search --no-floppy --set=root --file /boot/vmlinuz" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    linux /boot/vmlinuz boot=live live-media-path=live-$1 persistence persistence-label=ldata components splash" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "    initrd /boot/initrd.img" >> "$ISO_DIR/boot/grub/grub.cfg"
        echo "}" >> "$ISO_DIR/boot/grub/grub.cfg"
    }
    link_base mate
    link_base kde
    link_base xfce
    link_base lxqt
    link_base lxde
    link_base cinnamon
    
    # 2. 在 xorriso 中加入 UEFI 引导参数 (-eltorito-alt-boot 及之后的参数)
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

    echo "[+] 制作成功！双启动 ISO 镜像路径: $OUTPUT_ISO"
}

case "${1:-all}" in
    prep)
        step_prep
        ;;
    xorg)
        step_xorg
        ;;
    dev)
        step_dev
        ;;
    mate)
        step_gui mate
        ;;
    kde)
        step_gui kde
        ;;
    xfce)
        step_gui xfce
        ;;
    lxqt)
        step_gui lxqt
        ;;
    lxde)
        step_gui lxde
        ;;
    cinnamon)
        step_gui cinnamon
        ;;
    boot)
        step_boot
        ;;
    all)
        step_prep
        step_gui mate
        step_dev
        step_boot
        ;;
    *)
        echo "用法: $0 {prep|xorg|dev|(mate|kde|xfce|lxqt|lxde|cinnamon)|boot|all}"
        exit 1
        ;;
esac
