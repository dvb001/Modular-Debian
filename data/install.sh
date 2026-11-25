#!/bin/sh
ISO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -d "$ISO_DIR/live" ];then
    echo "invalid dir."
    exit 1
fi

VER=$(sed 's/\\n \\l//g' /etc/issue | head -n 1 | xargs)
if [ "$VER" == "" ]; then
    VER="System"
fi

step_partition_install() {
    echo "[+] Steps: Use GRUB to safely install a live system onto a specified disk/partition (non-destructive)..."
    if [ ! -d "$ISO_DIR" ]; then
        echo "[-] Error: ISO build directory not found: $ISO_DIR. Please run the packaging process first!"
        exit 1
    fi

    echo "[*] The list of disks and partitions currently in the system is as follows:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL

    echo ""
    read -p "Please enter the target partition name (e.g., sdb1 or sdc1):" TARGET_PART
    TARGET_PATH="/dev/$TARGET_PART"

    if [ ! -b "$TARGET_PATH" ]; then
        echo "[-] Error: Partition $TARGET_PATH does not exist!"
        exit 1
    fi

    # 自动推导整盘设备名（例如 sdb1 对应 /dev/sdb）
    TARGET_DISK="/dev/$(echo $TARGET_PART | sed 's/[0-9]*//g')"

    echo "=================================================="
    echo " Warning: You are about to copy files to partition $TARGET_PATH."
    echo " And write the GRUB bootloader to the MBR of the entire disk $TARGET_DISK!"
    echo "=================================================="
    read -p "Are you sure you want to continue? Please enter YES in uppercase to proceed: " CONFIRM

    if [ "$CONFIRM" != "YES" ]; then
        echo "[*] Operation cancelled."
        exit 0
    fi

    # 确保安装了 grub 相关工具
    apt install -y grub-pc-bin grub2-common rsync >/dev/null 2>&1 || true

    MNT_DIR="/mnt/debian-target-part"
    mkdir -p "$MNT_DIR"

    echo "[*] Mounting target partition..."
    umount "$TARGET_PATH" 2>/dev/null || true
    mount -o rw "$TARGET_PATH" "$MNT_DIR"

    echo "[*] Copying Live system files to the partition..."
    mkdir -p "$MNT_DIR/live" "$MNT_DIR/boot"
    rsync -aHAX --info=progress2 "$ISO_DIR/live/" "$MNT_DIR/live"
    rsync -aHAX --info=progress2 "$ISO_DIR/boot/" "$MNT_DIR/boot"

    echo "[*] Installing and configuring the GRUB bootloader..."
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
        local GRUB_CFGFILE="$MNT_DIR/boot/grub/grub.cfg"

        echo "menuentry \"Modular Live $VER Persistence\" {" >> "$GRUB_CFGFILE"
        echo "    linux /boot/vmlinuz boot=live persistence persistence-label=ldata components splash" >> "$GRUB_CFGFILE"
        echo "    initrd /boot/initrd.img" >> "$GRUB_CFGFILE"
        echo "}" >> "$GRUB_CFGFILE"

        echo "menuentry \"Modular Live $VER\" {" >> "$GRUB_CFGFILE"
        echo "    linux /boot/vmlinuz boot=live components splash" >> "$GRUB_CFGFILE"
        echo "    initrd /boot/initrd.img" >> "$GRUB_CFGFILE"
        echo "}" >> "$GRUB_CFGFILE"
    }

    write_boot_menu

    echo "[*] Synchronizing data and uninstalling..."
    sync
    umount "$MNT_DIR"
    echo "[+] Installation successful! GRUB has been successfully written to $TARGET_DISK via `grub-install`, and the boot menu has been configured."
}

step_partition_install
