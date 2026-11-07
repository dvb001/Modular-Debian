#!/bin/sh
ISO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$ISO_DIR/live" ];then
    echo "invalid dir."
    exit 1
fi

step_partition_install() {
    echo "[+] 步骤: 使用 GRUB 安全安装 Live 系统到指定磁盘/分区（非破坏性）..."
    if [ ! -d "$ISO_DIR" ]; then
        echo "[-] 错误: 未找到 ISO 构建目录: $ISO_DIR，请先执行打包！"
        exit 1
    fi

    echo "[*] 当前系统中的磁盘和分区列表如下："
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL

    echo ""
    read -p "请输入目标分区名称（例如 sdb1 或 sdc1）: " TARGET_PART
    TARGET_PATH="/dev/$TARGET_PART"

    if [ ! -b "$TARGET_PATH" ]; then
        echo "[-] 错误: 分区 $TARGET_PATH 不存在！"
        exit 1
    fi

    # 自动推导整盘设备名（例如 sdb1 对应 /dev/sdb）
    TARGET_DISK="/dev/$(echo $TARGET_PART | sed 's/[0-9]*//g')"

    echo "=================================================="
    echo " 警告：即将向分区 $TARGET_PATH 复制文件，"
    echo " 并将 GRUB 引导写入整盘 $TARGET_DISK 的 MBR！"
    echo "=================================================="
    read -p "确认要继续吗？请输入大写的 YES 继续: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "[*] 操作已取消。"
        exit 0
    fi

    # 确保安装了 grub 相关工具
    apt install -y grub-pc-bin grub2-common rsync >/dev/null 2>&1 || true

    MNT_DIR="/mnt/debian-target-part"
    mkdir -p "$MNT_DIR"

    echo "[*] 正在挂载目标分区..."
    umount "$TARGET_PATH" 2>/dev/null || true
    mount -o rw "$TARGET_PATH" "$MNT_DIR"

    echo "[*] 正在将 Live 系统文件复制到分区中..."
    mkdir -p "$MNT_DIR/live" "$MNT_DIR/boot"
    rsync -aHAX --info=progress2 "$ISO_DIR/live/" "$MNT_DIR/live"
    rsync -aHAX --info=progress2 "$ISO_DIR/boot/" "$MNT_DIR/boot"

    echo "[*] 正在安装并配置 GRUB 引导..."
    # 创建 grub 目录结构
    mkdir -p "$MNT_DIR/boot/grub"

    # 执行 grub-install 写入 MBR 并关联引导目录
    # 注意：--boot-directory 指向挂载点内的 boot 目录
    grub-install --target=i386-pc --boot-directory="$MNT_DIR/boot" "$TARGET_DISK"

    # 自动生成标准 grub.cfg 配置文件
    cat <<EOF > "$MNT_DIR/boot/grub/grub.cfg"
set timeout=20
set default=0

EOF

    write_boot_menu() {
        if [ ! -f "$MNT_DIR/live/004-$1.squashfs" ];then
            return
        fi

        local LIVE_DIR="$MNT_DIR/live-$1"
        rm -rf "$LIVE_DIR"
        mkdir -p "$LIVE_DIR"
        ln -f "$MNT_DIR/live/001-base.squashfs" "$LIVE_DIR/"
        ln -f "$MNT_DIR/live/002-devtools.squashfs" "$LIVE_DIR/"
        ln -f "$MNT_DIR/live/003-xorg.squashfs" "$LIVE_DIR/"
        ln -f "$MNT_DIR/live/004-$1.squashfs" "$LIVE_DIR/"

        local GRUB_CFGFILE="$MNT_DIR/boot/grub/grub.cfg"

        echo "menuentry \"Debian 12 Modular Live $1 (GRUB)\" {" >> "$GRUB_CFGFILE"
        echo "    linux /boot/vmlinuz boot=live live-media-path=live-$1 persistence persistence-label=ldata components splash" >> "$GRUB_CFGFILE"
        echo "    initrd /boot/initrd.img" >> "$GRUB_CFGFILE"
        echo "}" >> "$GRUB_CFGFILE"
    }

    write_boot_menu mate
    write_boot_menu kde
    write_boot_menu xfce
    write_boot_menu lxqt
    write_boot_menu lxde
    write_boot_menu cinnamon

    echo "[*] 正在同步数据并卸载..."
    sync
    umount "$MNT_DIR"
    echo "[+] 安装成功！GRUB 已经通过 grub-install 成功写入 $TARGET_DISK，启动菜单配置完毕。"
}

step_partition_install