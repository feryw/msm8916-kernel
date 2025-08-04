#!/bin/bash
set -e

ARCH="$1"

if [ "$ARCH" == "armv8" ]; then
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

DOWNLOAD_SERVER="images.linuxcontainers.org"
DOWNLOAD_INDEX_PATH="/meta/1.0/index-system"
DOWNLOAD_DISTRO="debian;bullseye;${DISTRO_ARCH};default"

DTB_FILE="msm8916-yiming-uz801v3.dtb"
RAMDISK_FILE="initrd.img"
ROOTFS_DIR="rootfs-$ARCH"

mkdir -p "$ROOTFS_DIR"

# Fetch rootfs tarball URL
echo "==> Downloading rootfs metadata..."
ROOTFS_URL="https://$DOWNLOAD_SERVER$(curl -fsSL "https://$DOWNLOAD_SERVER$DOWNLOAD_INDEX_PATH" | grep "$DOWNLOAD_DISTRO" | cut -f6 -d';')rootfs.tar.xz"

echo "==> Downloading rootfs from $ROOTFS_URL"
curl -L -o rootfs.tar.xz "$ROOTFS_URL"
tar -xf rootfs.tar.xz -C "$ROOTFS_DIR"
rm rootfs.tar.xz

# Setup chroot script
cat <<EOF | tee "$ROOTFS_DIR/tmp/chroot.sh" > /dev/null
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"

cat <<EOI > /etc/fstab
PARTUUID=$PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOI

rm /etc/resolv.conf 
echo "nameserver 8.8.8.8" > /etc/resolv.conf

apt-get update
apt-get install -y initramfs-tools
dpkg -i -y /tmp/*.deb

EOF

chmod 755 "$ROOTFS_DIR/tmp/chroot.sh"
cp ../../artifacts/linux-image-*.deb $ROOTFS_DIR/tmp/

# Bind mounts
echo "==> Entering chroot to build kernel and install..."
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
mount --bind /sys "$ROOTFS_DIR/sys"

LANG=C LANGUAGE=C LC_ALL=C chroot "$ROOTFS_DIR" /tmp/chroot.sh

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
cat Image.gz $DTB_FILE > kernel-dtb
mkbootimg \
    --base 0x80000000 \
    --kernel_offset 0x00080000 \
    --ramdisk_offset 0x02000000 \
    --tags_offset 0x01e00000 \
    --pagesize 2048 \
    --second_offset 0x00f00000 \
    --ramdisk "$RAMDISK_FILE" \
    --cmdline "earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200" \
    --kernel kernel-dtb -o boot.img

mv boot.img ../../artifacts/
