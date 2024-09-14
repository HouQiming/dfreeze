#!/bin/busybox sh
/bin/busybox mkdir -p /sbin /usr/bin /usr/sbin /proc /sys /dev /sysroot /tmp \
        /media/cdrom /media/usb /run /lib /sysroot /usr/lib /home
/bin/busybox --install -s
#echo "sh loaded"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

abort_to_shell() {
	#while true ;do
	echo "$1"
	/bin/sh
	#done
	exit 1
}

mkdir -p /sbin /usr/bin /usr/sbin /proc /sys /dev /sysroot /tmp /run /lib /sysroot /usr/lib

[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755,size=2M devtmpfs /dev 2>/dev/null \
	|| mount -t tmpfs -o exec,nosuid,mode=0755,size=2M tmpfs /dev

#echo "basic runtime up"

depmod -a
INITRDX=`cat /proc/cmdline | sed -e 's/^.*initrd=//' -e 's/ .*$//' -e 's%\\\%/%g'`
ESPUUID=`cat /proc/cmdline | sed -e 's/^.*espuuid=//' -e 's/ .*$//'`
COUNTER=0
while true
do
	#echo "waiting for esp ${ESPUUID}"
	#echo "initrd is ${INITRDX}"
	grep -h MODALIAS /sys/bus/*/devices/*/uevent | cut -d= -f2 | xargs modprobe -abq 2>/dev/null
	BLKID_OUTPUT=`blkid`
	ESPPATH=`echo "${BLKID_OUTPUT}"|grep "${ESPUUID}"|cut -d: -f1`
	if [ -z "${ESPPATH}" ]
	then
		if [ ${COUNTER} -lt 10 ]
		then
			COUNTER=$(( COUNTER + 1 ))
			sleep 0.5s
		else
			break
		fi
	else
		break
	fi
done

if [ -z "${ESPPATH}" ]
then
	echo "ESPUUID is ${ESPUUID}"
	echo "INITRDX is ${INITRDX}"
	abort_to_shell "unable to locate the ESP"
fi

echo "copy rootfs.sfs from ${ESPPATH}"

loadsfs(){
	mkdir -p /mnt/efi
	modprobe fat
	modprobe vfat
	modprobe exfat
	mount -o ro "${ESPPATH}" /mnt/efi || mount -o ro -t vfat "${ESPPATH}" /mnt/efi || return 1
	BOOTDIR=`dirname "/mnt/efi/${INITRDX}"`
	cp "${BOOTDIR}/rootfs.sfs" /rootfs.sfs
	umount /mnt/efi
	
	#mount the squashfs hierarchy
	modprobe loop
	modprobe squashfs
	modprobe overlay
	mkdir -p /sysroot
	mount -t ramfs ramfs /sysroot
	mkdir -p /sysroot/lower /sysroot/upper /sysroot/work /sysroot/root
	mount -t squashfs /rootfs.sfs /sysroot/lower || return 1
	mount -t overlay overlay -olowerdir=/sysroot/lower,upperdir=/sysroot/upper,workdir=/sysroot/work /sysroot/root || return 1
}

loadsfs &
# attempt to mount LUKS while we load the sfs
LUKSPATH=`echo "${BLKID_OUTPUT}"|grep "${ESPPATH%?}"|grep "LUKS"|cut -d: -f1`
if [ -e "${LUKSPATH}" ]
then
	echo "found LUKS home at ${LUKSPATH}"
	modprobe dm-crypt
	modprobe ext4
	#modprobe btrfs
	retry() {
		sleep 1s
		cryptsetup --allow-discards luksOpen "${LUKSPATH}" luksroot
	}
	cryptsetup --allow-discards luksOpen "${LUKSPATH}" luksroot
	[ -e /dev/mapper/luksroot ] || retry
	[ -e /dev/mapper/luksroot ] || retry
	if [ -e /dev/mapper/luksroot ]
	then
		fsck.ext4 /dev/mapper/luksroot
		wait || abort_to_shell "failed to setup root sfs"
		mkdir -p /sysroot/root/luks
		mount -o errors=remount-ro /dev/mapper/luksroot /sysroot/root/luks || abort_to_shell "unable to mount the decrypted ${LUKSPATH}"
		if [ -e /sysroot/root/luks/home ]
		then
			mount --bind /sysroot/root/luks/home /sysroot/root/home
		else
			mount --bind /sysroot/root/luks /sysroot/root/home
		fi
	else
		echo "LUKS setup canceled"
	fi
fi

wait || abort_to_shell "failed to setup root sfs"

INIT=/sbin/init
if [ -e /sysroot/root/init ]
then
	INIT=/init
fi

[ -e "/sysroot/root${INIT}" ] || abort_to_shell "sysroot not bootable"

echo "switch_root and run ${INIT}...\n"
exec switch_root /sysroot/root ${INIT}
abort_to_shell "failed to switch_root"
