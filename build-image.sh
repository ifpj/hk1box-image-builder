#!/bin/bash
set -euo pipefail

# ========================================================================
# HK1 Box (Amlogic S905X3) 镜像构建脚本
# 输入: mmdebstrap tarball + ophub 内核四件套 + u-boot 文件
# 输出: 可直接启动的 .img.gz 镜像
# ========================================================================

error_msg() { echo "[ERROR] $1" >&2; exit 1; }
info_msg()  { echo "[INFO]  $1"; }

# ---- 解析参数 ----
TARBALL=""
KERNEL_BOOT=""
KERNEL_DTB=""
KERNEL_MODULES=""
UBOOT_MBR=""       # hk1box-u-boot.bin.sd.bin
UBOOT_EXT=""       # u-boot-x96maxplus.bin → /boot/u-boot.ext
DISTRO=""
SUITE=""
OUTPUT_PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tarball)       TARBALL="$2"; shift 2 ;;
    --kernel-boot)   KERNEL_BOOT="$2"; shift 2 ;;
    --kernel-dtb)    KERNEL_DTB="$2"; shift 2 ;;
    --kernel-modules) KERNEL_MODULES="$2"; shift 2 ;;
    --uboot-mbr)     UBOOT_MBR="$2"; shift 2 ;;
    --uboot-ext)     UBOOT_EXT="$2"; shift 2 ;;
    --distro)        DISTRO="$2"; shift 2 ;;
    --suite)         SUITE="$2"; shift 2 ;;
    --output)        OUTPUT_PREFIX="$2"; shift 2 ;;
    *) error_msg "Unknown parameter: $1" ;;
  esac
done

[[ -z "$TARBALL" ]]     && error_msg "--tarball is required"
[[ -z "$KERNEL_BOOT" ]] && error_msg "--kernel-boot is required"
[[ -z "$KERNEL_DTB" ]]  && error_msg "--kernel-dtb is required"
[[ -z "$KERNEL_MODULES" ]] && error_msg "--kernel-modules is required"
[[ -z "$UBOOT_MBR" ]]   && error_msg "--uboot-mbr is required"
[[ -z "$UBOOT_EXT" ]]   && error_msg "--uboot-ext is required"
[[ -z "$DISTRO" ]]      && error_msg "--distro is required"
[[ -z "$SUITE" ]]       && error_msg "--suite is required"
[[ -z "$OUTPUT_PREFIX" ]] && error_msg "--output is required"

# ---- 提取内核名称 ----
# boot-6.12.69-ophub.tar.gz → 6.12.69-ophub
KERNEL_NAME="$(basename "$KERNEL_BOOT" .tar.gz)"
KERNEL_NAME="${KERNEL_NAME#boot-}"
info_msg "Kernel name: $KERNEL_NAME"

# ---- HK1 Box 固定参数 ----
PLATFORM="amlogic"
SOC="s905x3"
FDTFILE="meson-sm1-hk1box-vontar-x3.dtb"
FAMILY="meson-sm1"
BOOT_CONF="uEnv.txt"
BOOT_MB="180"
SKIP_MB="4"
BOOTFS_TYPE="fat32"
ROOTFS_TYPE="ext4"

# ---- 创建工作目录 ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_BOOTFS="${SCRIPT_DIR}/bootfs"
[[ -d "$PLATFORM_BOOTFS" ]] || error_msg "platform bootfs not found: $PLATFORM_BOOTFS"

TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

TAG_BOOTFS="$TMPDIR/bootfs"
tag_rootfs="$TMPDIR/rootfs"
EXTRACT_ROOTFS="$TMPDIR/extracted_rootfs"
BUILD_IMAGE="$TMPDIR/build.img"
mkdir -p "$TAG_BOOTFS" "$tag_rootfs" "$EXTRACT_ROOTFS"

# ==== 步骤1: 解压 tarball 估算 rootfs 大小 ====
info_msg "Extracting tarball to estimate size..."
zstd -d "$TARBALL" -o "$TMPDIR/tarball.tar"
sudo tar xf "$TMPDIR/tarball.tar" -C "$EXTRACT_ROOTFS"

ROOTFS_BYTES="$(sudo du -sb "$EXTRACT_ROOTFS" | cut -f1)"
ROOTFS_MB="$(( ROOTFS_BYTES / 1024 / 1024 ))"

# 估算完整 modules 解压后的大小。完整 modules 要复制到 rootfs，必须计入分区容量。
info_msg "Estimating full kernel modules size..."
MODULES_BYTES="$(tar -tvzf "$KERNEL_MODULES" | awk '{sum += $3} END {print sum+0}')"
MODULES_MB="$(( (MODULES_BYTES + 1024*1024 - 1) / 1024 / 1024 ))"

# rootfs 分区 = rootfs内容 + 完整modules + 200MB buffer，然后向上取整到 10MB
RAW_ROOTFS_PART_MB="$(( ROOTFS_MB + MODULES_MB + 200 ))"
ROOTFS_PART_MB="$(( ((RAW_ROOTFS_PART_MB + 9) / 10) * 10 ))"

TOTAL_MB="$(( SKIP_MB + BOOT_MB + ROOTFS_PART_MB ))"
info_msg "Rootfs content: ${ROOTFS_MB}MB"
info_msg "Kernel modules estimated: ${MODULES_MB}MB"
info_msg "Image size: ${TOTAL_MB}MB (boot=${BOOT_MB}, rootfs=${ROOTFS_PART_MB})"

# ==== 步骤2: 创建空白镜像 ====
info_msg "Creating blank image (${TOTAL_MB}MB)..."
truncate -s "${TOTAL_MB}M" "$BUILD_IMAGE"

# ==== 步骤3: 分区 ====
info_msg "Partitioning (msdos)..."
parted -s "$BUILD_IMAGE" mklabel msdos 2>/dev/null
parted -s "$BUILD_IMAGE" mkpart primary fat32 "${SKIP_MB}MiB" "$((SKIP_MB + BOOT_MB - 1))MiB" 2>/dev/null
parted -s "$BUILD_IMAGE" mkpart primary ext4 "$((SKIP_MB + BOOT_MB))MiB" 100% 2>/dev/null

# ==== 步骤4: losetup ====
LOOP_DEV="$(sudo losetup -P -f --show "$BUILD_IMAGE")"
[[ -n "$LOOP_DEV" ]] || error_msg "losetup failed"
trap "sudo umount '$TAG_BOOTFS' '$tag_rootfs' 2>/dev/null || true; sudo losetup -d '$LOOP_DEV' 2>/dev/null || true; rm -rf '$TMPDIR'" EXIT

# ==== 步骤5: 生成 rootfs UUID ====
ROOTFS_UUID="$(cat /proc/sys/kernel/random/random_uuid 2>/dev/null || uuidgen)"
info_msg "ROOTFS_UUID(planned)=$ROOTFS_UUID"

# ==== 步骤6: 格式化，并读取真实 UUID ====
info_msg "Formatting bootfs (vfat)..."
sudo mkfs.vfat -F 32 -n "BOOT" "${LOOP_DEV}p1" >/dev/null 2>&1
info_msg "Formatting rootfs (ext4)..."
sudo mkfs.ext4 -F -q -U "$ROOTFS_UUID" -L "ROOTFS" -b 4096 -m 0 "${LOOP_DEV}p2" >/dev/null 2>&1

# 读取格式化后的真实 UUID。vfat 的 UUID 是 XXXX-XXXX，不能使用 Linux random_uuid。
BOOT_UUID="$(sudo blkid -s UUID -o value "${LOOP_DEV}p1")"
ROOTFS_UUID_REAL="$(sudo blkid -s UUID -o value "${LOOP_DEV}p2")"
[[ -n "$BOOT_UUID" ]] || error_msg "failed to read bootfs UUID"
[[ -n "$ROOTFS_UUID_REAL" ]] || error_msg "failed to read rootfs UUID"
ROOTFS_UUID="$ROOTFS_UUID_REAL"
info_msg "BOOT_UUID(actual)=$BOOT_UUID"
info_msg "ROOTFS_UUID(actual)=$ROOTFS_UUID"

# ==== 步骤7: 写入 u-boot MBR ====
info_msg "Writing u-boot MBR..."
sudo dd if="$UBOOT_MBR" of="$LOOP_DEV" conv=fsync bs=1 count=444 2>/dev/null
sudo dd if="$UBOOT_MBR" of="$LOOP_DEV" conv=fsync bs=512 skip=1 seek=1 2>/dev/null

# ==== 步骤8: 挂载 ====
info_msg "Mounting partitions..."
sudo mount "${LOOP_DEV}p1" "$TAG_BOOTFS"
sudo mount "${LOOP_DEV}p2" "$tag_rootfs"

# ==== 步骤8.5: 复制 rootfs 和 Amlogic boot scripts ====
info_msg "Copying rootfs content into image..."
sudo cp -a "$EXTRACT_ROOTFS/." "$tag_rootfs/"

info_msg "Copying Amlogic boot scripts..."
# bootfs is FAT32; do not preserve Unix ownership/mode.
sudo cp -r --no-preserve=ownership,mode "$PLATFORM_BOOTFS/." "$TAG_BOOTFS/"

# ==== 步骤9: 提取内核 boot 必要文件到 /boot ====
info_msg "Extracting required kernel boot files..."
BOOT_EXTRACT="$TMPDIR/boot_extract"
mkdir -p "$BOOT_EXTRACT"
sudo tar -mxzf "$KERNEL_BOOT" -C "$BOOT_EXTRACT"
SRC_VMLINUZ="$BOOT_EXTRACT/vmlinuz-${KERNEL_NAME}"
SRC_UINITRD="$BOOT_EXTRACT/uInitrd-${KERNEL_NAME}"
[[ -f "$SRC_VMLINUZ" ]] || error_msg "vmlinuz-${KERNEL_NAME} not found in boot tarball"
[[ -f "$SRC_UINITRD" ]] || error_msg "uInitrd-${KERNEL_NAME} not found in boot tarball"

# Detect TEXT_OFFSET patch: 0108 -> patched -> u-boot.ext not needed
NEED_UBOOT_EXT="yes"
TEXTOFF="$(hexdump -n 15 -x "$SRC_VMLINUZ" 2>/dev/null | awk 'NR==1{print $7}')"
[[ "$TEXTOFF" == "0108" ]] && NEED_UBOOT_EXT="no"
info_msg "TEXT_OFFSET marker: ${TEXTOFF:-unknown}, need u-boot.ext: ${NEED_UBOOT_EXT}"

sudo cp -f "$SRC_VMLINUZ" "$TAG_BOOTFS/zImage"
sudo cp -f "$SRC_UINITRD" "$TAG_BOOTFS/uInitrd"

# ==== 步骤10: 提取目标 dtb 到 /boot 根目录 ====
info_msg "Extracting target dtb..."
DTB_EXTRACT="$TMPDIR/dtb_extract"
mkdir -p "$DTB_EXTRACT"
sudo tar -mxzf "$KERNEL_DTB" -C "$DTB_EXTRACT"
NEEDED_DTB="$(find "$DTB_EXTRACT" -name "$FDTFILE" | head -1)"
[[ -n "$NEEDED_DTB" && -f "$NEEDED_DTB" ]] || error_msg "DTB not found after extraction: $FDTFILE"
sudo cp -f "$NEEDED_DTB" "$TAG_BOOTFS/${FDTFILE}"
OC_DTB="$(find "$DTB_EXTRACT" -name "${FDTFILE%.dtb}-oc.dtb" | head -1)"
[[ -n "$OC_DTB" && -f "$OC_DTB" ]] && sudo cp -f "$OC_DTB" "$TAG_BOOTFS/${FDTFILE%.dtb}-oc.dtb"

# ==== 步骤11: 解压完整 modules ====
info_msg "Extracting full kernel modules..."
sudo mkdir -p "${tag_rootfs}/usr/lib/modules"
sudo tar -mxzf "$KERNEL_MODULES" -C "${tag_rootfs}/usr/lib/modules" || {
  echo "[ERROR] Failed to extract modules: $KERNEL_MODULES"
  ls -lh "$KERNEL_MODULES"
  exit 1
}
DST_MOD_DIR="${tag_rootfs}/usr/lib/modules/${KERNEL_NAME}"
[[ -d "$DST_MOD_DIR" ]] || error_msg "modules dir not found after extract: $DST_MOD_DIR"
info_msg "Full modules size: $(sudo du -sh "$DST_MOD_DIR" | awk '{print $1}')"
info_msg "Rootfs used after modules: $(sudo du -sh "$tag_rootfs" | awk '{print $1}')"
sudo df -h "$tag_rootfs" || true
sudo df -i "$tag_rootfs" || true

# ==== 步骤12: 按需复制 u-boot.ext ====
if [[ "$NEED_UBOOT_EXT" == "yes" ]]; then
  sudo cp -f "$UBOOT_EXT" "${TAG_BOOTFS}/u-boot.ext"
  info_msg "u-boot.ext copied."
else
  info_msg "u-boot.ext skipped."
fi
# bootfs 是 FAT32，不支持 Unix 权限位，无需 chmod

# ==== 步骤13: 创建 uEnv.txt ====
cat > "$TMPDIR/uEnv.txt" <<EOF
LINUX=/zImage
INITRD=/uInitrd
FDT=/${FDTFILE}
APPEND=root=UUID=${ROOTFS_UUID} rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 suspend_env_cfg=off cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF
sudo cp -f "$TMPDIR/uEnv.txt" "${TAG_BOOTFS}/uEnv.txt"

# ==== 步骤14: 创建 /etc/fstab 和基础系统配置 ====
sudo bash -c "cat > '${tag_rootfs}/etc/fstab' <<'FSTAB'
UUID=${ROOTFS_UUID}  /      ext4  defaults,noatime,nodiratime,commit=600,errors=remount-ro  0 1
UUID=${BOOT_UUID}    /boot  vfat  defaults,noatime                                      0 2
tmpfs                /tmp   tmpfs defaults,nosuid                                        0 0
FSTAB"

# hostname / hosts
sudo bash -c "cat > '${tag_rootfs}/etc/hostname' <<'EOF'
hk1box
EOF
cat > '${tag_rootfs}/etc/hosts' <<'EOF'
127.0.0.1   localhost
127.0.1.1   hk1box
EOF"

# systemd-networkd: eth* DHCP
sudo mkdir -p "${tag_rootfs}/etc/systemd/network"
sudo bash -c "cat > '${tag_rootfs}/etc/systemd/network/20-wired.network' <<'EOF'
[Match]
Name=eth*

[Network]
DHCP=yes
EOF"

# enable networkd and ssh
sudo mkdir -p "${tag_rootfs}/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /lib/systemd/system/systemd-networkd.service \
  "${tag_rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
sudo ln -sf /lib/systemd/system/ssh.service \
  "${tag_rootfs}/etc/systemd/system/multi-user.target.wants/ssh.service"

# test convenience: root/root and allow SSH password login
sudo chroot "${tag_rootfs}" /bin/sh -c "echo 'root:root' | chpasswd" || true
if [[ -f "${tag_rootfs}/etc/ssh/sshd_config" ]]; then
  sudo sed -i \
    -e 's|^#*PermitRootLogin.*|PermitRootLogin yes|' \
    -e 's|^#*PasswordAuthentication.*|PasswordAuthentication yes|' \
    "${tag_rootfs}/etc/ssh/sshd_config"
fi

# ==== 步骤15: umount ====
info_msg "Unmounting..."
sudo sync
sudo umount "$TAG_BOOTFS"
sudo umount "$tag_rootfs"
sudo losetup -d "$LOOP_DEV"

# ==== 步骤20: 压缩输出 ====
OUTPUT_FILE="${OUTPUT_PREFIX}_${KERNEL_NAME}.img"
OUTPUT_GZ="${OUTPUT_FILE}.gz"
info_msg "Compressing to ${OUTPUT_GZ}..."
sudo cp "$BUILD_IMAGE" "$OUTPUT_FILE"
if command -v pigz >/dev/null 2>&1; then
  pigz -qf "$OUTPUT_FILE"
else
  gzip -qf "$OUTPUT_FILE"
fi

# 生成 sha256
sha256sum "$OUTPUT_GZ" > "${OUTPUT_GZ}.sha256"

info_msg "Done: $(ls -lh "$OUTPUT_GZ")"
# When running under sudo, GITHUB_OUTPUT may be unavailable; the workflow does not depend on this output.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "image=${OUTPUT_GZ}" >> "$GITHUB_OUTPUT"
fi
