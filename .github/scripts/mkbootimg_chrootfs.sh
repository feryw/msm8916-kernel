#!/bin/bash
set -e

ARCH="$1"

if [ "$ARCH" == "arm64" ]; then
  DISTRO_ARCH="arm64"
  DTB_DIR="usr/lib/linux-image*/qcom"
  CROSS_COMPILE="aarch64-linux-gnu-"
  KERNEL_ARCH="arm64"
else
  DISTRO_ARCH="armhf"
  DTB_DIR="usr/lib"
  CROSS_COMPILE="arm-linux-gnueabihf-"
  KERNEL_ARCH="arm"
fi

PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
DOWNLOAD_SERVER="images.linuxcontainers.org"
DOWNLOAD_INDEX_PATH="/meta/1.0/index-system"
DOWNLOAD_DISTRO="debian;bullseye;${DISTRO_ARCH};default"

DTB_FILE="msm8916-yiming-uz801v3.dtb"
RAMDISK_FILE="initrd.img"
ROOTFS_DIR="rootfs-$ARCH"
ARTIFACTS_DIR="../../artifacts"
KERNEL_SRC_DIR="$(pwd)/../../"

mkdir -p "$ROOTFS_DIR"

# Fetch rootfs tarball URL
echo "==> Downloading rootfs metadata..."
ROOTFS_URL="https://$DOWNLOAD_SERVER$(curl -fsSL "https://$DOWNLOAD_SERVER$DOWNLOAD_INDEX_PATH" | grep "$DOWNLOAD_DISTRO" | cut -f6 -d';')rootfs.tar.xz"

echo "==> Downloading rootfs from $ROOTFS_URL"
curl -L -o rootfs.tar.xz "$ROOTFS_URL"
tar -xf rootfs.tar.xz -C "$ROOTFS_DIR"
rm rootfs.tar.xz

# Copy kernel source into chroot
echo "==> Copying kernel source..."
mkdir -p "$ROOTFS_DIR/workspace"
rsync -a --exclude='.git' "$KERNEL_SRC_DIR/" "$ROOTFS_DIR/workspace/"

# Setup chroot script
cat <<EOF | sudo tee "$ROOTFS_DIR/tmp/chroot.sh" > /dev/null
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "nameserver 8.8.8.8" > /etc/resolv.conf

apt-get update
apt-get install -y ccache build-essential bc kmod cpio flex libncurses5-dev libelf-dev \
  libssl-dev dwarves bison crossbuild-essential-${DISTRO_ARCH} fakeroot debhelper rsync patchutils \
  xz-utils lzop liblz4-tool binfmt-support mkbootimg initramfs-tools wireless-regdb apt-utils

cd /workspace
make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE} mrproper
make ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE} uz801v3_defconfig
fakeroot make -j\$(nproc) ARCH=${KERNEL_ARCH} CROSS_COMPILE=${CROSS_COMPILE} CC="ccache ${CROSS_COMPILE}gcc" KBUILD_DEBARCH=${DISTRO_ARCH} bindeb-pkg -d

dpkg -i ../linux-image-*.deb || apt-get install -f -y
EOF

chmod +x "$ROOTFS_DIR/tmp/chroot.sh"

# Bind mounts
echo "==> Entering chroot to build kernel and install..."
sudo mount --bind /proc "$ROOTFS_DIR/proc"
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
sudo mount --bind /sys "$ROOTFS_DIR/sys"
sudo cp /usr/bin/qemu-arm-static "$ROOTFS_DIR/usr/bin/"

sudo chroot "$ROOTFS_DIR" /bin/bash /tmp/chroot.sh

# Unmount
sudo umount "$ROOTFS_DIR/proc"
sudo umount "$ROOTFS_DIR/dev/pts"
sudo umount "$ROOTFS_DIR/dev"
sudo umount "$ROOTFS_DIR/sys"

# Extract boot artifacts
KERNEL_IMG=$(find "$ROOTFS_DIR/boot" -name "vmlinuz*" | head -n1)
INITRD_IMG=$(find "$ROOTFS_DIR/boot" -name "initrd.img*" | head -n1)
DTB_PATH=$(find "$ROOTFS_DIR/$DTB_DIR" -name "*uz801v3.dtb" | head -n1)

cp "$KERNEL_IMG" Image.gz
cp "$INITRD_IMG" initrd.img
cp "$DTB_PATH" "$DTB_FILE"

echo "==> Building boot.img..."
mkbootimg \
    --base 0x80000000 \
    --kernel_offset 0x00080000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --pagesize 2048 \
    --second_offset 0x00f00000 \
    --ramdisk "$RAMDISK_FILE" \
    --cmdline "earlycon root=PARTUUID=$PARTUUID console=ttyMSM0,115200 no_framebuffer=true rw" \
    --kernel kernel-dtb -o boot.img

mkdir -p "$ARTIFACTS_DIR"
mv ../linux-*.deb "$ARTIFACTS_DIR/"
mv boot.img "$ARTIFACTS_DIR/boot-$ARCH.img"

echo "==> Done. Artifacts saved in $ARTIFACTS_DIR"
