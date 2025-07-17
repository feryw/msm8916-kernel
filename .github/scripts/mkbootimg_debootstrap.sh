#!/bin/bash
set -e

ARCH="$1"
PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"
DTB_FILE="msm8916-yiming-uz801v3.dtb"
RAMDISK_FILE="initrd.img"

if [ "$ARCH" == "arm64" ]; then
  DISTRO_ARCH="arm64"
  DEBARCH="arm64"
  QEMU_ARCH="aarch64"
else
  DISTRO_ARCH="armhf"
  DEBARCH="armhf"
  QEMU_ARCH="arm"
fi

ROOTFS_DIR="rootfs-$ARCH"
IMAGE_ARTIFACTS="../../artifacts"
DEB_IMAGE=$(realpath $IMAGE_ARTIFACTS/linux-image-*.deb)

echo "==> Creating minimal Debian rootfs for $ARCH"

mkdir -p "$ROOTFS_DIR"
sudo debootstrap --arch="$DEBARCH" --foreign bookworm "$ROOTFS_DIR" http://deb.debian.org/debian
sudo cp "/usr/bin/qemu-$QEMU_ARCH-static" "$ROOTFS_DIR/usr/bin/"
sudo chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage

echo "==> Configuring rootfs..."

cat <<EOF | sudo tee "$ROOTFS_DIR/tmp/setup.sh" > /dev/null
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "nameserver 8.8.8.8" > /etc/resolv.conf

cat <<EOI > /etc/fstab
PARTUUID=$PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOI

apt-get update
apt-get install -y initramfs-tools
dpkg -i /tmp/linux-image-*.deb || apt-get install -f -y
EOF

chmod +x "$ROOTFS_DIR/tmp/setup.sh"

# Copy .deb package into rootfs
sudo cp "$DEB_IMAGE" "$ROOTFS_DIR/tmp/"
sudo chroot "$ROOTFS_DIR" /bin/bash /tmp/setup.sh

# Extract built files
KERNEL_IMG=$(find "$ROOTFS_DIR/boot" -name "vmlinuz*" | head -n1)
INITRD_IMG=$(find "$ROOTFS_DIR/boot" -name "initrd.img*" | head -n1)
DTB_PATH=$(find "$ROOTFS_DIR/usr/lib/linux-image*" -name "*uz801v3*.dtb" | head -n1)

cp "$KERNEL_IMG" Image.gz
cp "$INITRD_IMG" initrd.img
cp "$DTB_PATH" "$DTB_FILE"

echo "==> Building boot.img"

cat Image.gz "$DTB_FILE" > kernel-dtb

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

mkdir -p "$IMAGE_ARTIFACTS"
mv boot.img "$IMAGE_ARTIFACTS/boot-$ARCH.img"

echo "==> Boot image created at $IMAGE_ARTIFACTS/boot-$ARCH.img"
