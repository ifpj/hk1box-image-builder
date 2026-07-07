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
KERNEL_HEADER=""
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
    --kernel-header) KERNEL_HEADER="$2"; shift 2 ;;
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
[[ -z "$KERNEL_HEADER" ]]  && error_msg "--kernel-header is required"
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
BOOT_MB="256"
SKIP_MB="4"
BOOTFS_TYPE="fat32"
ROOTFS_TYPE="ext4"

# ---- 创建工作目录 ----
TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

TAG_BOOTFS="$TMPDIR/bootfs"
tag_rootfs="$TMPDIR/rootfs"
BUILD_IMAGE="$TMPDIR/build.img"
mkdir -p "$TAG_BOOTFS" "$tag_rootfs"

# ==== 步骤1: 解压 tarball 估算 rootfs 大小 ====
info_msg "Extracting tarball to estimate size..."
zstd -d "$TARBALL" -o "$TMPDIR/tarball.tar"
sudo tar xf "$TMPDIR/tarball.tar" -C "$tag_rootfs"

ROOTFS_BYTES="$(sudo du -sb "$tag_rootfs" | cut -f1)"
ROOTFS_MB="$(( ROOTFS_BYTES / 1024 / 1024 ))"
# rootfs 分区 = tarball × 2 + 256MB buffer，但至少 1024MB
ROOTFS_PART_MB="$(( ROOTFS_MB * 2 + 256 ))"
[[ "$ROOTFS_PART_MB" -lt 1024 ]] && ROOTFS_PART_MB="1024"

TOTAL_MB="$(( SKIP_MB + BOOT_MB + ROOTFS_PART_MB ))"
info_msg "Rootfs content: ${ROOTFS_MB}MB"
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
trap "sudo losetup -d '$LOOP_DEV' 2>/dev/null; rm -rf '$TMPDIR'" EXIT

# ==== 步骤5: 生成 UUID ====
BOOT_UUID="$(cat /proc/sys/kernel/random/random_uuid 2>/dev/null || uuidgen)"
ROOTFS_UUID="$(cat /proc/sys/kernel/random/random_uuid 2>/dev/null || uuidgen)"
info_msg "BOOT_UUID=$BOOT_UUID"
info_msg "ROOTFS_UUID=$ROOTFS_UUID"

# ==== 步骤6: 格式化 ====
info_msg "Formatting bootfs (vfat)..."
sudo mkfs.vfat -F 32 -n "BOOT" "${LOOP_DEV}p1" >/dev/null 2>&1
info_msg "Formatting rootfs (ext4)..."
sudo mkfs.ext4 -F -q -U "$ROOTFS_UUID" -L "ROOTFS" -b 4096 -m 0 "${LOOP_DEV}p2" >/dev/null 2>&1

# ==== 步骤7: 写入 u-boot MBR ====
info_msg "Writing u-boot MBR..."
sudo dd if="$UBOOT_MBR" of="$LOOP_DEV" conv=fsync bs=1 count=444 2>/dev/null
sudo dd if="$UBOOT_MBR" of="$LOOP_DEV" conv=fsync bs=512 skip=1 seek=1 2>/dev/null

# ==== 步骤8: 挂载 ====
info_msg "Mounting partitions..."
sudo mount "${LOOP_DEV}p1" "$TAG_BOOTFS"
sudo mount "${LOOP_DEV}p2" "$tag_rootfs"

# ==== 步骤9: 解压内核 boot 到 /boot ====
info_msg "Extracting kernel boot files..."
sudo tar -mxzf "$KERNEL_BOOT" -C "$TAG_BOOTFS"
(cd "$TAG_BOOTFS" && sudo cp -f "vmlinuz-${KERNEL_NAME}" zImage && sudo cp -f "uInitrd-${KERNEL_NAME}" uInitrd)

# ==== 步骤10: 解压 dtb ====
info_msg "Extracting dtb files..."
sudo mkdir -p "$TAG_BOOTFS/dtb/amlogic"
sudo tar -mxzf "$KERNEL_DTB" -C "$TAG_BOOTFS/dtb/amlogic"
sudo ln -sf dtb "${TAG_BOOTFS}/dtb-${KERNEL_NAME}"

# ==== 步骤11: 解压 modules ====
info_msg "Extracting kernel modules..."
sudo tar -mxzf "$KERNEL_MODULES" -C "${tag_rootfs}/usr/lib/modules"
HEADER_PATH="linux-headers-${KERNEL_NAME}"
sudo mkdir -p "${tag_rootfs}/usr/src/${HEADER_PATH}"
sudo tar -mxzf "$KERNEL_HEADER" -C "${tag_rootfs}/usr/src/${HEADER_PATH}"

# 建立 build 符号链接
sudo bash -c "cd '${tag_rootfs}/usr/lib/modules/${KERNEL_NAME}/' && rm -f build source && ln -sf /usr/src/${HEADER_PATH} build"

# ==== 步骤12: 复制 u-boot.ext ====
sudo cp -f "$UBOOT_EXT" "${TAG_BOOTFS}/u-boot.ext"
sudo chmod +x "${TAG_BOOTFS}/u-boot.ext"

# ==== 步骤13: 创建 uEnv.txt ====
cat > "$TMPDIR/uEnv.txt" <<EOF
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/${FDTFILE}
APPEND=root=UUID=${ROOTFS_UUID} rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 suspend_env_cfg=off cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1
EOF
sudo cp -f "$TMPDIR/uEnv.txt" "${TAG_BOOTFS}/uEnv.txt"

# ==== 步骤14: 创建 armbianEnv.txt ====
cat > "$TMPDIR/armbianEnv.txt" <<EOF
verbosity=1
bootlogo=false
overlay_prefix=${FAMILY}
fdtfile=${FDTFILE}
rootdev=UUID=${ROOTFS_UUID}
rootfstype=ext4
rootflags=rw,errors=remount-ro
usbstoragequirks=0x2537:0x1066:u,0x1058:0x1078:u
EOF
sudo cp -f "$TMPDIR/armbianEnv.txt" "${TAG_BOOTFS}/armbianEnv.txt"

# ==== 步骤15: 创建 /etc/fstab ====
sudo bash -c "cat > '${tag_rootfs}/etc/fstab' <<'FSTAB'
UUID=${ROOTFS_UUID}  /      ext4  defaults,noatime,nodiratime,commit=600,errors=remount-ro  0 1
UUID=${BOOT_UUID}    /boot  vfat  defaults                                               0 2
tmpfs                /tmp   tmpfs defaults,nosuid                                        0 0
FSTAB"

# ==== 步骤16: 修复符号链接 ====
info_msg "Fixing symlinks..."
sudo bash -c "
  cd '${tag_rootfs}'
  rm -f bin lib sbin
  ln -sf usr/bin bin
  ln -sf usr/lib lib
  ln -sf usr/sbin sbin
  rm -f var/lock var/run
  ln -sf /run/lock var/lock
  ln -sf /run var/run
"

# ==== 步骤17: 修复权限 ====
sudo bash -c "
  cd '${tag_rootfs}'
  [[ -d 'var/tmp' ]] && chmod 777 var/tmp
  [[ -f 'etc/sudoers' ]] && chown root:root etc/sudoers && chmod 440 etc/sudoers
  [[ -f 'usr/bin/sudo' ]] && chown root:root usr/bin/sudo && chmod 4755 usr/bin/sudo
"

# ==== 步骤18: 清理不必要的文件 ====
info_msg "Cleaning up unnecessary files..."
sudo bash -c "
  cd '${tag_rootfs}'
  # 删除 Armbian 品牌残留（如果 tarball 里已有）
  rm -rf usr/share/armbian 2>/dev/null || true
  rm -rf usr/lib/nand-sata-install 2>/dev/null || true
  rm -f etc/apt/sources.list.save 2>/dev/null || true
  rm -rf usr/share/doc/linux-image-* 2>/dev/null || true
  rm -rf usr/lib/linux-image-* 2>/dev/null || true
  # 删除 motd-news
  rm -f usr/lib/systemd/system/motd-news.* 2>/dev/null || true
  rm -f etc/update-motd.d/50-motd-news 2>/dev/null || true
  # 删除 dpkg 残留
  rm -f var/lib/dpkg/info/linux-image* 2>/dev/null || true
"

# ==== 步骤19: umount ====
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
echo "image=${OUTPUT_GZ}" >> "$GITHUB_OUTPUT"
