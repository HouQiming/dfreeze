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
	
	#mount the squashfs hierarchy
	modprobe loop
	modprobe squashfs
	modprobe overlay
	mkdir -p /sysroot
	#tmpfs instead of ramfs for overlayfs xattrs
	mount -t tmpfs tmpfs /sysroot
	mkdir -p /sysroot/lower /sysroot/upper /sysroot/work /sysroot/root
	mount -t squashfs /rootfs.sfs /sysroot/lower || return 1
	mount -t overlay overlay /sysroot/root -olowerdir=/sysroot/lower,upperdir=/sysroot/upper,workdir=/sysroot/work || return 1
	#clobber grub!
	rm -rf /sysroot/root/etc/grub* /sysroot/root/etc/default/grub \
		/sysroot/root/usr/sbin/update-grub /sysroot/root/usr/bin/update-grub \
		/sysroot/root/bin/update-grub /sysroot/root/sbin/update-grub
	#emulate /boot for recursive dfreeze, but point it to ramfs
	mkdir -p /sysroot/root/boot/efi
	mkdir -p /sysroot/root/home
	cp -a /home/* /sysroot/root/home/
	cp "${BOOTDIR}/linux64.efi" /sysroot/root/boot/vmlinuz
	umount /mnt/efi
}

loadsfs &
# attempt to mount LUKS while we load the sfs
LUKSPATH=`echo "${BLKID_OUTPUT}"|grep "${ESPPATH%?}"|grep "LUKS"|cut -d: -f1`
echo "LUKSPATH is ${LUKSPATH}"
if [ -z "${LUKSPATH}" ]
then
	LUKSPATH=`echo "${BLKID_OUTPUT}"|grep "LUKS"|cut -d: -f1`
fi
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
	if [ -e /dev/mapper/luksroot ]
	then
		fsck.ext4 /dev/mapper/luksroot
		wait || abort_to_shell "failed to setup root sfs"
		mkdir -p /sysroot/root/luks
		mount -o errors=remount-ro /dev/mapper/luksroot /sysroot/root/luks || abort_to_shell "unable to mount the decrypted ${LUKSPATH}"
		rmdir /sysroot/root/home/*
		#ln -s /sysroot/root/luks /luks
		if [ -e /sysroot/root/luks/home ]
		then
			#ln -s /luks/home/* /sysroot/root/home/
			mount --bind /sysroot/root/luks/home /sysroot/root/home
		else
			#ln -s /luks/* /sysroot/root/home/
			mount --bind /sysroot/root/luks /sysroot/root/home
		fi
	else
		echo "LUKS setup canceled"
	fi
fi

wait || abort_to_shell "failed to setup root sfs"

#setup remount script
if [ -e "${LUKSPATH}" ]
then
#LUKSPATH is /dev/sd?? and won't remain valid after disk yanking
LUKSUUID=`blkid "${LUKSPATH}"|cut -d ' ' -f2|sed 's/.*="//;s/"//'`
mkdir -p /sysroot/root/usr/bin/
##########################
cat > /sysroot/root/usr/bin/remount-home <<EOF
#!/bin/sh
if [ "\${EUID}" -ne 0 ]
then
	echo "we need sudo"
	exit 1
fi
umount /home 2>/dev/null
umount -f /home 2>/dev/null
umount /luks 2>/dev/null
umount -f /luks 2>/dev/null
#this can't possibly work after disk yanking: it'll be still in-use
#cryptsetup luksClose luksroot 2>/dev/null
set -e
NEW_DM_NAME=\$(basename \$(mktemp -u))
cryptsetup --allow-discards luksOpen "/dev/disk/by-uuid/${LUKSUUID}" "\${NEW_DM_NAME}" || exit
fsck.ext4 "/dev/mapper/\${NEW_DM_NAME}"
mount -o errors=remount-ro "/dev/mapper/\${NEW_DM_NAME}" /luks || exit
if [ -e /luks/home ]
then
	mount --bind /luks/home /home
else
	mount --bind /luks /home
fi
EOF
##########################
chmod +x /sysroot/root/usr/bin/remount-home
fi

INIT=/sbin/init
if [ -e /sysroot/root/init ]
then
	INIT=/init
fi

[ -e "/sysroot/root${INIT}" ] || abort_to_shell "sysroot not bootable"

echo "switch_root and run ${INIT}..."
exec switch_root /sysroot/root ${INIT}
abort_to_shell "failed to switch_root"
