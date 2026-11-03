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
BASE_CHROOT="$WORK_DIR/base-chroot"
GUI_CHROOT="$WORK_DIR/gui-chroot"
DEV_CHROOT="$WORK_DIR/dev-chroot"

GUI_STAGE="$WORK_DIR/gui-stage"
DEV_STAGE="$WORK_DIR/dev-stage"

ISO_DIR="$WORK_DIR/iso"
OUTPUT_ISO="$WORK_DIR/debian-12-modular.iso"

rm_stage_temps() {
    rm -f "$1/etc/passwd" "$1/etc/shadow" "$1/etc/group" \
          "$1/etc/gshadow" "$1/etc/machine-id" "$1/etc/hostname" \
          "$1/etc/hosts"
}

step_prep() {
    echo "[+] 步骤 1/4: 构建基础系统 (001-base)..."
    apt update || true
    apt install -y debootstrap squashfs-tools initramfs-tools isolinux syslinux-utils xorriso rsync || true

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

step_gui() {
    echo "[+] 步骤 2/4: 构建 MATE 桌面增量模块 (002-mate)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mountting overlay systems..."
    read -p "Remove last stage? [y/N]" choice
    if [[ "choice" =~ ^[Yy]$ ]]; then
        rm -rf "$GUI_CHROOT" "$GUI_STAGE" "$WORK_DIR/gui-workdir"
    fi
    mkdir -p "$GUI_CHROOT" "$GUI_STAGE" "$WORK_DIR/gui-workdir"

    # 使用 overlay 挂载
    mount -t overlay overlay \
        -o lowerdir="$BASE_CHROOT",upperdir="$GUI_STAGE",workdir="$WORK_DIR/gui-workdir" \
        "$GUI_CHROOT" # 这里的 GUI_CHROOT 就是你的合并挂载点

    echo "[*] 在 GUI Chroot 中安装 MATE 桌面及相关软件..."
    chroot "$GUI_CHROOT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt update && \
        apt install -y --no-install-recommends \
            mate-desktop-environment-core \
            lightdm \
            network-manager-gnome \
            firefox-esr \
            gparted \
            xserver-xorg \
            xserver-xorg-core \
            xinit \
            x11-xserver-utils \
            fonts-noto-cjk fonts-noto-cjk-extra \
            engrampa \
            pluma pluma-plugins \
            mesa-utils && \
        apt clean
    "
    sleep 2
    umount "$GUI_CHROOT" 2>/dev/null || true
    
    patch_base() {
        # 2. 提取 MATE 安装时生成的系统服务账号，追加到 Base 的 passwd/group 中，避免服务因为找不到账号失败
        echo "[*] 正在同步 MATE 模块的系统服务账号至 Base..."
        awk -F: '$3 < 1000 {print}' "$GUI_STAGE/etc/passwd" | while read -r line; do
            username=$(echo "$line" | cut -d: -f1)
            if ! grep -q "^$username:" "$BASE_CHROOT/etc/passwd"; then
                echo "$line" >> "$BASE_CHROOT/etc/passwd"
            fi
        done
        awk -F: '$3 < 1000 {print}' "$GUI_STAGE/etc/group" | while read -r line; do
            groupname=$(echo "$line" | cut -d: -f1)
            if ! grep -q "^$groupname:" "$BASE_CHROOT/etc/group"; then
                echo "$line" >> "$BASE_CHROOT/etc/group"
            fi
        done
        
        # 重新打包更完善的 Base 模块
        rm "$ISO_DIR/live/001-base.squashfs" 2>/dev/null ||true
        mksquashfs "$BASE_CHROOT" "$ISO_DIR/live/001-base.squashfs" -comp xz

        rm_stage_temps "$GUI_STAGE"
    }
    
    # 3. 打包排重后的增量模块
    echo "[*] 打包 002-mate.squashfs..."
    rm "$ISO_DIR/live/002-mate.squashfs" 2>/dev/null || true
    mksquashfs "$GUI_STAGE" "$ISO_DIR/live/002-mate.squashfs" -comp xz
    echo "[+] 002-mate 增量模块构建完成！"
}

step_dev() {
    echo "[+] 步骤 3/4: 构建 DevTools 开发工具增量模块 (003-devtools)..."

    # 创建必要的挂载目录和工作目录
    echo "[*] mountting overlay systems..."
    read -p "Remove last stage? [y/N]" choice
    if [[ "choice" =~ ^[Yy]$ ]]; then
        rm -rf "$DEV_CHROOT" "$DEV_STAGE" "$WORK_DIR/dev-workdir"
    fi
    mkdir -p "$DEV_CHROOT" "$DEV_STAGE" "$WORK_DIR/dev-workdir"

    # 使用 overlay 挂载
    mount -t overlay overlay \
        -o lowerdir="$GUI_STAGE:$BASE_CHROOT",upperdir="$DEV_STAGE",workdir="$WORK_DIR/dev-workdir" \
        "$DEV_CHROOT" # 这里的 GUI_CHROOT 就是你的合并挂载点

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
            linux-headers-amd64 gawk\
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
    echo "[*] 打包 003-devtools.squashfs..."
    rm "$ISO_DIR/live/003-devtools.squashfs" 2>/dev/null || true
    mksquashfs "$DEV_STAGE" "$ISO_DIR/live/003-devtools.squashfs" -comp xz
    echo "[+] 003-devtools 增量模块构建完成！"
}

step_boot() {
    echo "[+] 步骤 4/4: 提取内核、配置引导并生成 ISO..."

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

    cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
    cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/"

    cat <<EOF > "$ISO_DIR/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT debian-modular

LABEL debian-modular
    MENU LABEL Start Debian 12 Modular
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live components splash
LABEL debian-modular-with-persistence
    MENU LABEL Start Debian 12 Modular (persistence) 
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live persistence persistence-label=ldata components splash
EOF

    echo "[*] 正在生成 ISO 镜像: $OUTPUT_ISO"
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "DEBIAN_MODULAR" \
        -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -output "$OUTPUT_ISO" \
        "$ISO_DIR"

    echo "[+] 制作成功！ISO 镜像路径: $OUTPUT_ISO"
}

case "${1:-all}" in
    prep)
        step_prep
        ;;
    gui)
        step_gui
        ;;
    dev)
        step_dev
        ;;
    boot)
        step_boot
        ;;
    all)
        step_prep
        step_gui
        step_dev
        step_boot
        ;;
    *)
        echo "用法: $0 {prep|gui|dev|boot|all}"
        exit 1
        ;;
esac
