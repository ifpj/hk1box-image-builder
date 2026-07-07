# hk1box-image-builder

为 **HK1 Box (Amlogic S905X3)** 盒子构建最小可启动镜像。

## 原理

从 [mmdebstrap-rootfs-builder](https://github.com/ifpj/mmdebstrap-rootfs-builder) 生成的 tarball 出发，注入 [ophub/kernel](https://github.com/ophub/kernel) 最新 `kernel_stable` 内核和 [ophub/u-boot](https://github.com/ophub/u-boot) bootloader，生成可直接启动的 `.img.gz` 镜像。

**不**基于已有 Armbian 镜像重建，而是从零组装，因此镜像干净、最小。

## 镜像分区布局

| 分区 | 格式 | 大小 | 说明 |
|------|------|------|------|
| boot | FAT32 | 256 MB | zImage + uInitrd + dtb + uEnv.txt |
| rootfs | ext4 | tarball × 2 + 256MB 缓冲 | 最小系统 |

## Release 产物

推送 `v*` 开头的 tag 后，Actions 会自动构建并上传：

| 文件 | 说明 |
|------|------|
| `debian-trixie_${KERNEL}.img.gz` | Debian 13 (trixie) 可启动镜像 |
| `ubuntu-resolute_${KERNEL}.img.gz` | Ubuntu 26.04 LTS (resolute) 可启动镜像 |
| `*.sha256` | SHA256 校验 |

## 使用

### 烧录到 SD 卡

```bash
# Linux
unzstd debian-trixie_6.12.69-ophub.img.gz -o /dev/sdX

# 或先用 gunzip 解压，再用 dd
gunzip debian-trixie_6.12.69-ophub.img.gz
dd if=debian-trixie_6.12.69-ophub.img of=/dev/sdX bs=4M status=progress
```

### 手动触发构建

进入 **Actions** → **Build HK1 Box bootable image** → **Run workflow**，可选择自定义 tarball release tag（默认 `latest`）。

## 本地构建（需要在 ARM64 Linux 上）

```bash
# 1. 准备依赖
sudo apt update
sudo apt install -y zstd parted dosfstools e2fsprogs curl jq pigz git

# 2. 下载内核四件套（替换为实际版本）
for f in boot-6.12.69-ophub.tar.gz dtb-amlogic-6.12.69-ophub.tar.gz \
         modules-6.12.69-ophub.tar.gz header-6.12.69-ophub.tar.gz; do
  curl -fsSL "https://github.com/ophub/kernel/releases/download/kernel_stable/${f}" -o /tmp/${f}
done

# 3. 下载 tarball
curl -fsSL "https://github.com/ifpj/mmdebstrap-rootfs-builder/releases/latest/download/debian-trixie-minbase-arm64.tar.zst" \
  -o /tmp/debian-trixie-minbase-arm64.tar.zst

# 4. 下载 u-boot
git clone --depth 1 https://github.com/ophub/u-boot.git /tmp/u-boot-repo

# 5. 执行构建脚本
sudo ./build-image.sh \
  --tarball /tmp/debian-trixie-minbase-arm64.tar.zst \
  --kernel-boot /tmp/boot-6.12.69-ophub.tar.gz \
  --kernel-dtb /tmp/dtb-amlogic-6.12.69-ophub.tar.gz \
  --kernel-modules /tmp/modules-6.12.69-ophub.tar.gz \
  --kernel-header /tmp/header-6.12.69-ophub.tar.gz \
  --uboot-mbr /tmp/u-boot-repo/amlogic/bootloader/hk1box-u-boot.bin.sd.bin \
  --uboot-ext /tmp/u-boot-repo/amlogic/bootloader/u-boot-x96maxplus.bin \
  --distro debian --suite trixie \
  --output debian-trixie_6.12.69-ophub
```

## License

MIT
