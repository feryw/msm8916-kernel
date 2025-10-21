#!/bin/bash
set -e

ARCH="$1"

if [ "$ARCH" == "armv8" ]; then
  DISTRO_ARCH="arm64"
  DTB_DIR="usr/lib/linux-image*/qcom"
else
  DISTRO_ARCH="armhf"
  DTB_DIR="usr/lib"
fi

DOWNLOAD_SERVER="images.linuxcontainers.org"
DOWNLOAD_INDEX_PATH="/meta/1.0/index-system"
DOWNLOAD_DISTRO="ubuntu;jammy;${DISTRO_ARCH};default"

DTB_FILE="msm8916-yiming-uz801v3.dtb"
RAMDISK_FILE="initrd.img"
ROOTFS_DIR="rootfs-$DISTRO_ARCH"
ARTIFACTS_DIR="./artifacts"
PARTUUID="a7ab80e8-e9d1-e8cd-f157-93f69b1d141e"

pwd
find "$ARTIFACTS_DIR"

mkdir -p "$ROOTFS_DIR"


# Fetch & extract rootfs tarball URL
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

cat <<EOI > /etc/fstab
PARTUUID=$PARTUUID / ext4 defaults,noatime,commit=600,errors=remount-ro 0 1
tmpfs /tmp tmpfs defaults,nosuid 0 0
EOI

rm /etc/resolv.conf 
echo "nameserver 8.8.8.8" > /etc/resolv.conf

apt-get update
apt-get install -y apt-utils
apt-get install -y wireless-regdb initramfs-tools
dpkg -i /tmp/linux-image-*.deb || apt-get install -f -y
EOF

chmod 755 "$ROOTFS_DIR/tmp/chroot.sh"
cp "$ARTIFACTS_DIR/linux-image-*.deb" $ROOTFS_DIR/tmp/

# Bind mounts
echo "==> Entering chroot to make initramfs"
sudo mount --bind /proc "$ROOTFS_DIR/proc"
sudo mount --bind /dev "$ROOTFS_DIR/dev"
sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
sudo mount --bind /sys "$ROOTFS_DIR/sys"

LANG=C LANGUAGE=C LC_ALL=C sudo chroot "$ROOTFS_DIR" /tmp/chroot.sh

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
    --cmdline "earlycon root=PARTUUID=$PARTUUID console=ttyMSM0,115200" \
    --kernel kernel-dtb -o boot.img

mv boot.img "$ARTIFACTS_DIR/boot-$ARCH.img"
echo "==> Done. Boot image saved at $ARTIFACTS_DIR/boot-$ARCH.img"
