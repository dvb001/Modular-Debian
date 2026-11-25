#!/usr/bin/env python3
import os
import glob
import shutil
import subprocess

STATUS_FILE = "/var/lib/dpkg/status"
INFO_DIR = "/var/lib/dpkg/info"
ROOTFS_DIR = "/run/live/rootfs"

def parse_status_file(filepath):
    """解析 dpkg status 文件，返回以 package 名为 key 的段落字典"""
    packages = {}
    if not os.path.exists(filepath):
        return packages
    
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    paragraphs = content.split('\n\n')
    for para in paragraphs:
        if not para.strip():
            continue
        lines = para.split('\n')
        pkg_name = None
        for line in lines:
            if line.startswith('Package:'):
                pkg_name = line.split(':', 1)[1].strip()
                break
        if pkg_name:
            packages[pkg_name] = para
    return packages

def main():
    if not os.path.exists(INFO_DIR):
        print(f"[!] Info dir {INFO_DIR} not found.")
        return

    # 1. 精准获取 /var/lib/dpkg/info/ 下所有实际安装的包名（剥离 :amd64 等多架构后缀）
    installed_in_info = set()
    for f in os.listdir(INFO_DIR):
        if f.endswith('.list'):
            raw_name = f[:-5]  # 去掉 .list
            pkg_name = raw_name.split(':', 1)[0]  # 剥离架构后缀，如 libc6:amd64 -> libc6
            installed_in_info.add(pkg_name)

    print(f"[*] Found {len(installed_in_info)} clean packages in {INFO_DIR}.")

    # 2. 寻找 /run/live/rootfs/ 各挂载点中文件最大的 status 文件作为备用库
    largest_status_file = None
    max_size = 0
    if os.path.exists(ROOTFS_DIR):
        try:
            with os.scandir(ROOTFS_DIR) as entries:
                for entry in entries:
                    if entry.is_dir():
                        s_file = os.path.join(entry.path, "var/lib/dpkg/status")
                        if os.path.isfile(s_file):
                            try:
                                size = os.path.getsize(s_file)
                                if size > max_size:
                                    max_size = size
                                    largest_status_file = s_file
                            except OSError:
                                continue
        except PermissionError:
            pass

    fallback_packages = {}
    if largest_status_file:
        print(f"[*] Found largest fallback status file: {largest_status_file} (Size: {max_size} bytes)")
        fallback_packages = parse_status_file(largest_status_file)

    # 3. 加载当前系统的 status 文件
    current_packages = parse_status_file(STATUS_FILE)

    # 4. 开始修正 status
    new_packages = {}
    for pkg in installed_in_info:
        stanza = None
        if pkg in current_packages:
            stanza = current_packages[pkg]
        elif pkg in fallback_packages:
            stanza = fallback_packages[pkg]
            print(f"[+] Recovered missing package stanza from fallback: {pkg}")
        else:
            # 严禁捏造低版本号！如果两边都找不到其完整的 stanza，
            # 说明该包记录残缺，直接跳过或者从系统 dpkg 中安全获取，
            # 绝对不写 1.0-0+livedefault 破坏依赖树。
            print(f"[!] Warning: Package '{pkg}' has info list but no status record anywhere. Skipping to avoid dependency break.")
            continue

        # 强制修正 Status 行为 installed
        lines = stanza.split('\n')
        new_lines = []
        status_updated = False
        for line in lines:
            if line.startswith('Status:'):
                new_lines.append('Status: install ok installed')
                status_updated = True
            else:
                new_lines.append(line)
        if not status_updated:
            new_lines.append('Status: install ok installed')
        
        new_packages[pkg] = '\n'.join(new_lines)

    # 5. 备份原 status 文件
    if os.path.exists(STATUS_FILE):
        shutil.copy(STATUS_FILE, STATUS_FILE + ".bak")

    # 6. 写回修正后的 status 文件
    with open(STATUS_FILE, 'w', encoding='utf-8') as f:
        for pkg in sorted(new_packages.keys()):
            f.write(new_packages[pkg] + '\n\n')

    print(f"[*] Dpkg status successfully synchronized. Total active packages: {len(new_packages)}")

if __name__ == '__main__':
    main()