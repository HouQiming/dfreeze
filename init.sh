#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

abort_to_shell() {
	while true ;do
		printf "%s\n" "$1"
		/bin/sh
	done
	exit 1
}

mkdir -p /sbin /usr/bin /usr/sbin /proc /sys /dev /sysroot /tmp /run /lib /sysroot /usr/lib

[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
mount -t proc -o noexec,nosuid,nodev proc /proc
mount -t sysfs -o noexec,nosuid,nodev sysfs /sys
mount -t devtmpfs -o exec,nosuid,mode=0755,size=2M devtmpfs /dev 2>/dev/null \
	|| mount -t tmpfs -o exec,nosuid,mode=0755,size=2M tmpfs /dev

INITRDX=`cat /proc/cmdline | sed -e 's/^.*initrd=//' -e 's/ .*$//' -e 's%\\%/%g'`
ESPUUID=`cat /proc/cmdline | sed -e 's/^.*espuuid=//' -e 's/ .*$//'`
while [ "${TO_BOOT}" = "refresh" ]
do
	grep -h MODALIAS /sys/bus/*/devices/*/uevent | cut -d= -f2 | xargs modprobe -abq 2>/dev/null
	BLKID_OUTPUT=`blkid`
	ESPPATH=`echo "${BLKID_OUTPUT}"|grep "PARTUUID=\"${ESPUUID}\""|cut -d: -f1`
	if [ -z "${ESPPATH}" ]
	then
		if [ ${COUNTER} -lt 10 ]
		then
			COUNTER=$(( COUNTER + 1 ))
			sleep 0.5s
			continue
		fi
	fi
done

mkdir -p /mnt/efi
mkdir -p /sysroot/lower /sysroot/upper /sysroot/work /sysroot/root
mount -o ro "${ESPPATH}" /mnt/efi || abort_to_shell "failed to mount ESP"
BOOTDIR=`dirname "/mnt/efi/${INITRDX}"`
cp "${BOOTDIR}/rootfs.sfs" /rootfs.sfs
umount /mnt/efi

#mount the squashfs hierarchy
modprobe squashfs
mount -t squashfs /rootfs.sfs /sysroot/lower
mount -t ramfs ramfs /sysroot/upper
mount -t ramfs ramfs /sysroot/work
mount -t overlay overlay -olowerdir=/sysroot/lower,upperdir=/sysroot/upper,workdir=/sysroot/work /sysroot/root

INIT=/sbin/init
if [ -e /sysroot/root/init ]
then
	INIT=/init
fi

printf "switch_root and run ${INIT}...\n"
exec switch_root /sysroot/root ${INIT}
abort_to_shell "failed to switch_root"
