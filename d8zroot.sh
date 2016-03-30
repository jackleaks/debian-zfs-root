###############################################################################
#
# Debian Jessie (version 8) installation script for ZFS root filesystem
#
# Copyright : Francois Scala @2016
# License   : GPL v3
#
###############################################################################

# Debian
DEBIANDIST=jessie
#DEBIANMIRROR="http://ftp.us.debian.org/debian"
DEBIANMIRROR="http://ftp.ch.debian.org/debian"

# ZFS
POOL=rpool
ZFSRELEASE=zfsonlinux_6_all.deb

###############################################################################
# customize your partition scheme here
function do_partitions {

DISK=/dev/sda
PARTBOOT=${DISK}1
PARTSWAP=${DISK}2
PARTZROOT=${DISK}3
BOOTPARAM=${DISK}

apt-get update
apt-get install -y gdisk

sgdisk --clear  ${DISK}
sgdisk -n 1::+1G    -c 1:"BOOT"  -t 1:8300 ${DISK}
sgdisk -n 2::+2G    -c 2:"SWAP"  -t 2:8200 ${DISK}
sgdisk -n 3::       -c 3:"ZROOT" -t 3:bf00 ${DISK}
sgdisk -n 4:34:2047 -c 4:"BIOS"  -t 4:ef02 ${DISK}

# DEBUG : to reinstall on existing system
#dd if=/dev/zero of=${DISK}1 bs=1M count=1
#dd if=/dev/zero of=${DISK}2 bs=1M count=1
#dd if=/dev/zero of=${DISK}3 bs=1M count=1

mkfs.ext4 -L BOOT ${PARTBOOT}

mkswap -f -L SWAP ${PARTSWAP}
#swapon -va

}

###############################################################################
# customize your root password, user account here and other parameters
function do_user {

# Set root password
echo 'root:root' | chpasswd

# Create a user
adduser --gecos "Some User" --shell /bin/bash --disabled-password user
echo 'user:user' | chpasswd
#mkdir /home/user/.ssh
#cat > /home/user/.ssh/authorized_keys << _EOF
#ssh-rsa AAAAB3NzaC1yc2EAAAABJQA.....
#_EOF
#chown -R user.user /home/user/.ssh

# Locales
apt-get install -y locales
locale-gen en_US.UTF-8
locale-gen C.UTF-8
export LANG=C.UTF-8

# Misc
apt-get install -y tree htop ssh

# Automation (puppet, cfengine, ...)

}

###############################################################################
# customize your rpool setup
function do_rpool {

zpool create -o ashift=12 -o altroot=/mnt -m none ${POOL} ${PARTZROOT}
zfs set atime=off                                 ${POOL}

zfs create -o mountpoint=none                                              ${POOL}/ROOT
zfs create -o mountpoint=/                                                 ${POOL}/ROOT/debian-1

zpool set bootfs=${POOL}/ROOT/debian-1                                     ${POOL}

zfs create -o mountpoint=/home                                             ${POOL}/home
zfs create -o mountpoint=/usr -o canmount=off                              ${POOL}/usr
zfs create -o mountpoint=/var                                              ${POOL}/var
zfs create -o compression=lz4 -o atime=on                                  ${POOL}/var/mail
zfs create -o compression=lz4 -o setuid=off -o exec=off                    ${POOL}/var/log
zfs create -o compression=lz4 -o setuid=off -o exec=off                    ${POOL}/var/tmp
zfs create -o mountpoint=/tmp -o compression=lz4 -o setuid=off -o exec=off ${POOL}/tmp

}

###############################################################################
###############################################################################
###############################################################################
###############################################################################
###############################################################################
# Nothing should be change after this line

echo "==========================================================="
echo "==="
echo "=== Partitioning"
echo "==="
do_partitions

###############################################################################
echo "==========================================================="
echo "==="
echo "=== Install ZFS On Linux on Live image"
echo "==="
if [ ! -f ${ZFSRELEASE} ]
then
	wget http://archive.zfsonlinux.org/debian/pool/main/z/zfsonlinux/${ZFSRELEASE}
fi
dpkg -i ${ZFSRELEASE}
apt-get update
apt-get install -y linux-image-amd64 debian-zfs
modprobe zfs

###############################################################################
echo "==========================================================="
echo "==="
echo "=== Create ZFS Pool ${POOL}"
echo "==="
do_rpool

zpool export ${POOL}
zpool import -d /dev/disk/by-id -R /mnt ${POOL}

mkdir -p /mnt/etc/zfs/
zpool set cachefile=/mnt/etc/zfs/zpool.cache ${POOL}

mkdir -p /mnt/boot
mount /dev/disk/by-partlabel/BOOT /mnt/boot

###############################################################################
echo "==========================================================="
echo "==="
echo "=== Bootstrap Debian ${DEBIANDIST}"
echo "==="

apt-get install -y debootstrap
debootstrap ${DEBIANDIST} /mnt ${DEBIANMIRROR}

cp /etc/hostname /mnt/etc/
cp /etc/hosts /mnt/etc/
cp ${ZFSRELEASE} /mnt/tmp/

cat > /mnt/etc/fstab << _EOF
LABEL=BOOT	/boot	ext4	noatime	0	1
_EOF

cat > /mnt/etc/network/interfaces << _EOF
# interfaces(5) file used by ifup(8) and ifdown(8)
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
_EOF

# Generate chroot script
declare -f do_user > /mnt/tmp/chroot.sh
cat >> /mnt/tmp/chroot.sh << _EOF

cd /tmp/

do_user

echo "==========================================================="
echo "==="
echo "=== Install ZFS On Linux on target system"
echo "==="

apt-get install -y lsb-release
dpkg -i /tmp/${ZFSRELEASE}
apt-get update
apt-get install -y linux-image-amd64 debian-zfs

DEBIAN_FRONTEND=noninteractive apt-get install -y grub2-common grub-pc zfs-initramfs
grub-install --target=i386-pc --force ${BOOTPARAM}
mkdir -vp /boot/grub/
grub-mkconfig -o /boot/grub/grub.cfg

unset UCF_FORCE_CONFFOLD
export UCF_FORCE_CONFFNEW=YES
ucf --purge /boot/grub/menu.lst

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confnew" --force-yes -fuy dist-upgrade
#apt-get dist-upgrade

echo "==========================================================="
echo "==="
echo "=== Patching zfs-mount"
echo "==="

cd /lib/systemd/system/
cp -v zfs-mount.service zfs-mount.service.orig
patch --verbose -p0 << __EOP
--- zfs-mount.service.orig
+++ zfs-mount.service
@@ -8,6 +8,7 @@
 After=zfs-import-cache.service
 After=zfs-import-scan.service
 Before=local-fs.target
+Before=systemd-remount-fs.service

 [Service]
 Type=oneshot
__EOP

_EOF

###############################################################################
echo "==========================================================="
echo "==="
echo "=== Chroot installation step"
echo "==="

mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

chroot /mnt bash /tmp/chroot.sh 2>&1 /mnt/root/install-chroot.log

umount /mnt/boot
umount /mnt/dev
umount /mnt/proc
umount /mnt/sys
zfs umount -a
zpool export ${POOL}

echo "==========================================================="
echo "==========================================================="
echo "==========================================================="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "==="
echo "===     Installation completed."
echo "==="
echo "===     You can now remove the boot device and reboot to"
echo "===     your new installation"
echo "==="

###############################################################################