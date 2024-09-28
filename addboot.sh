#!/bin/sh
set -e
if [ "${EUID}" -ne 0 ]
then
	printf "we need sudo\n"
	exit 1
fi

ESPUUID=`cat /proc/cmdline | sed -e 's/^.*espuuid=//' -e 's/ .*$//'`
ESPPATH=`blkid|grep "${ESPUUID}"|cut -d: -f1`
efibootmgr -c -d "${ESPPATH%?}" -p "${ESPPATH: -1}" -l '\EFI\boot\bootx64.efi' -L 'dfreeze'
