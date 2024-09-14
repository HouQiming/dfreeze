#!/bin/sh
#`uname -m`
set -e
if [ "${EUID}" -ne 0 ]
then
	printf "we need sudo\n"
	exit 1
fi

WORK_DIR=`mktemp -d`
MODULES_DIR=/lib/modules/`uname -r`/kernel

copy_file(){
	set -e
	NAME="$1"
	DIR=`dirname ${NAME}`
	mkdir -p "${WORK_DIR}${DIR}"
	echo "${NAME}"
	cp -a "${NAME}" "${WORK_DIR}${NAME}"
}

copy_module(){
	set -e
	MODULE_FILES=`modprobe -D "$1"|grep insmod|cut -f 2 -d " "`
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

#rm -rI "${WORK_DIR}"
copy_module_dir drivers/nvme
copy_module_dir drivers/ata
copy_module_dir drivers/usb
copy_module_dir crypto
copy_module_dir lib
copy_module thunderbolt
copy_module uas
copy_module squashfs
copy_module fat
copy_module exfat
copy_module ext4
#copy_exe cryptsetup
echo "${WORK_DIR}"
cd "${WORK_DIR}"
du -hs
