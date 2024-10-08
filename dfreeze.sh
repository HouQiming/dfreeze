#!/bin/sh
#`uname -m`
set -e
if [ "${EUID}" -ne 0 ]
then
	printf "we need sudo\n"
	exit 1
fi

USER_NAME="${SUDO_USER}"
WORK_DIR=`mktemp -d`
WORK_DIR_INITRD="${WORK_DIR}/initrd"
if [ "${UNAME}" = "" ]
then
	UNAME=`uname -r`
fi
UNAME0=`uname -r`
MODULES_DIR="/lib/modules/${UNAME}/kernel"

echo "${UNAME} ${WORK_DIR}"

#initial detection
KERNEL_PATH="/boot/vmlinuz-${UNAME}"
if ! [ -e "${KERNEL_PATH}" ]
then
	KERNEL_PATH=/boot/vmlinuz
fi
if ! [ -e "${KERNEL_PATH}" ]
then
	printf "cannot locate kernel, tried %s\n" "${KERNEL_PATH}"
	exit 1
fi

copy_file(){
	set -e
	NAME="$1"
	DIR=`dirname ${NAME}`
	[ -e "${WORK_DIR_INITRD}${NAME}" ] && return
	mkdir -p "${WORK_DIR_INITRD}${DIR}"
	#echo "${NAME}"
	cp "${NAME}" "${WORK_DIR_INITRD}${NAME}"
}

copy_module(){
	set -e
	MODULE_FILES=`modprobe -D "$1"|grep insmod|cut -f 2 -d " "|sed 's/${UNAME0}/${UNAME}/g'`
	for i in ${MODULE_FILES}
	do
		copy_file "$i"
	done
}

copy_module_dir(){
	set -e
	MODULE_FILES=`find "${MODULES_DIR}/$1" -iname '*.ko*'`
	for i in ${MODULE_FILES}
	do
		BASE_I=`basename "$i"|cut -f 1 -d .`
		copy_module "${BASE_I}"
	done
}

copy_exe(){
	set -e
	NAME=`which $1`
	LIB_FILES=`ldd "${NAME}"|grep "=>"|cut -f 3 -d " "`
	copy_file "${NAME}"
	for i in ${LIB_FILES}
	do
		copy_file "$i"
	done
}

#create initrd
#rm -rI "${WORK_DIR_INITRD}"
mkdir -p ${WORK_DIR_INITRD}/kernel/x86/microcode

if [ -d /lib/firmware/amd-ucode ]; then
	cat /lib/firmware/amd-ucode/microcode_amd*.bin > ${WORK_DIR_INITRD}/kernel/x86/microcode/AuthenticAMD.bin
fi

if [ -d /lib/firmware/intel-ucode ]; then
	cat /lib/firmware/intel-ucode/* > ${WORK_DIR_INITRD}/kernel/x86/microcode/GenuineIntel.bin
fi

copy_module_dir drivers/nvme
copy_module_dir drivers/ata
copy_module_dir drivers/usb
#copy_module_dir drivers/mmc
#copy_module_dir drivers/scsi
copy_module_dir crypto
copy_module_dir lib
copy_module thunderbolt
copy_module uas
copy_module squashfs
copy_module fat
copy_module vfat
copy_module exfat
copy_module ext4
copy_module btrfs
copy_module overlay
copy_module loop
copy_module dm-crypt
copy_module virtio_blk
#copy_module ramfs
copy_file "/lib/modules/${UNAME}/modules.order"
copy_file "/lib/modules/${UNAME}/modules.builtin"
#copy_exe /bin/sh
#copy_exe mount
#copy_exe mkdir
#copy_exe dd
#copy_exe cat
#copy_exe grep
#copy_exe cut
#copy_exe xargs
#copy_exe sed
#copy_exe modprobe
#copy_exe insmod
#copy_exe switch_root
#copy_exe sleep
#copy_exe mknod
#copy_exe [
copy_exe blkid
copy_exe cryptsetup
copy_exe fsck.ext4
#the loader
LINKER=`ldd /bin/sh|tail -n1|cut -f2|cut -f1 -d " "`
copy_file "${LINKER}" 

MYDIR=`dirname $(realpath $0)`
if which busybox
then
	BUSYBOX=`which busybox`
else
	BUSYBOX="${MYDIR}/busybox"
fi
mkdir -p "${WORK_DIR_INITRD}/bin"
cp "${MYDIR}/init.sh" "${WORK_DIR_INITRD}/init"
cp "${BUSYBOX}" "${WORK_DIR_INITRD}/bin/busybox"

chmod +x "${WORK_DIR_INITRD}/init"
chmod +x "${WORK_DIR_INITRD}/bin/busybox"
mkdir -p "${WORK_DIR_INITRD}/home/${USER_NAME}"
chown "${USER_NAME}:${USER_NAME}" "${WORK_DIR_INITRD}/home/${USER_NAME}"

cd "${WORK_DIR_INITRD}"
printf "initrd size: "
du -hs
find . | cpio -o -H newc > ../initrdx.img

cd "${WORK_DIR}"
rm -rf ./initrd

#copy kernel
cp "${KERNEL_PATH}" "${WORK_DIR}/linux64.efi"

#create rootfs
cat >"${WORK_DIR}/exclude.lst" <<EOF
/tmp
/etc/fstab
/home
/luks
/var/log
${WORK_DIR}
EOF

cat /proc/mounts |cut -d ' ' -f 2 >> "${WORK_DIR}/exclude.lst"

#patch up bootx64
cp "${MYDIR}/bootx64.efi" "${WORK_DIR}/"
KRNLCMD_OFFSET=`grep -abo "KRNLCMD " "${WORK_DIR}/bootx64.efi"|cut -d: -f 1`
dd if=/dev/zero of="${WORK_DIR}/bootx64.efi" bs=1 count=128 seek=${KRNLCMD_OFFSET} conv=notrunc
EXTRA_CMDLINE="iommu=on intel_iommu=on"
CURRENT_CMDLINE=`cat /proc/cmdline | \
	sed 's/root=[^ ]*//' | \
	sed 's/rootflags=[^ ]*//' | \
	sed 's/initrd=[^ ]*//' | \
	sed 's/espuuid=[^ ]*//g' | \
	sed 's/BOOT_IMAGE=[^ ]*//' | \
	sed "s/${EXTRA_CMDLINE}//g" |
	sed 's/  */ /g'`
printf "${CURRENT_CMDLINE} ${EXTRA_CMDLINE}" | dd of="${WORK_DIR}/bootx64.efi" bs=1 seek=${KRNLCMD_OFFSET} conv=notrunc

rm -rf "${MYDIR}/build/output"
mkdir -p "${MYDIR}/build/output"

if [ "$1" = "rootfs" ]
then
	#-one-file-system fails on overlayfs
	mksquashfs / "${WORK_DIR}/rootfs.sfs" -comp zstd -ef "${WORK_DIR}/exclude.lst" 
fi

ESPUUID=`cat /proc/cmdline | sed -e 's/^.*espuuid=//' -e 's/ .*$//'`
INITRDX=`cat /proc/cmdline | sed -e 's/^.*initrd=//' -e 's/ .*$//' -e 's%\\\%/%g'`
ESPPATH=`blkid|grep "${ESPUUID}"|cut -d: -f1`
if [ -e "${ESPPATH}" ]
then
	mkdir -p /boot/efi
	mount "${ESPPATH}" /boot/efi
	BOOTDIR=`dirname "/boot/efi/${INITRDX}"`
	echo "installing to ${BOOTDIR}"
	cp "${WORK_DIR}/linux64.efi" "${WORK_DIR}/initrdx.img" "${WORK_DIR}/bootx64.efi" "${BOOTDIR}/"
	if [ "$1" = "rootfs" ]
	then
		mv "${WORK_DIR}/rootfs.sfs" "${BOOTDIR}/"
	fi
	umount /boot/efi
else
	mv "${WORK_DIR}/linux64.efi" "${WORK_DIR}/initrdx.img" "${WORK_DIR}/bootx64.efi" "${MYDIR}/build/output/"
	if [ "$1" = "rootfs" ]
	then
		mv "${WORK_DIR}/rootfs.sfs" "${MYDIR}/build/output/"
	fi
fi

rm "${WORK_DIR}/exclude.lst"
