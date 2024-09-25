## What it does

`sudo dfreeze.sh rootfs` packages your current Linux system into 4 files in `./build/output`:

```
bootx64.efi
linux64.efi
initrdx.img
rootfs.sfs 
```

Put them into the `/EFI/BOOT` folder of any FAT/VFAT/exFAT-formated USB stick. They should appear bootable in modern BIOS-es and can boot into an immutable copy of the Linux system you create them on, minus your home folder. You can make changes after you boot but they won't persist. If things fail, try partitioning the USB disk with GPT (the non-MBR partition table format, not the AI).

If you have any LUKS-encrypted ext4/btrfs partition on the same USB stick, it will be mounted to `/home` after a password prompt. Keep typing a wrong password to cancel that. If you have a `/home` folder on the LUKS partition, that `/home` will be mounted instead.

If you don't mount `/home`, you can unplug the USB stick after the system boots. Everything runs in RAM by that point. 

Your RAM size has to be larger enough to hold all your system files. At least 8G for a fresh install of popular workstation distros. Your disk has to be at least 50% empty if you run this on a newly-installed Linux system, which I recommend.

If you run `sudo dfreeze.sh` inside a system prepared by itself, it will perform an in-place update and persist whatever changes you made during the current boot. Omitting the `rootfs` part will avoid recreating `rootfs.sfs`, useful for a simple kernel update.

I strongly recommend uninstalling `grub` or any other bootloader and updating after the initial setup works. This project comes with its own bootloader.

In case the USB stick disconnects after the LUKS home partition were mounted, run `sudo remount-home` to hopefully fix it.

## Dependencies and building from source

At the minimum, you need `mksquashfs` (usually in `squashfs-tools`) for this to work. I provided two binaries, `busybox` and `bootx64.efi`, for convenience. If you don't trust them, install `busybox`, `clang`, `lld-link` from your distro and rebuild `bootx64.efi`. There is a `makefile` but you may need to change it to match your version.

The setup script uses GNU `grep` features and may not be compatible with more POSIX variants.

## Why

I have an old full-disk encrypted Linux system that fails to boot my new computer. This is my minimally intrusive way to fix it.

Note that all preparation work could be done from Windows without specialized disk writers. Just create a Linux VM, install some new distro, then format an exFAT partition, create `/EFI/BOOT` and copy the files to it from inside the VM. My Asus BIOS tries to boot any FAT disk without caring whether they're ESP so this hack works.

It can be useful if you like using a nomadic USB stick and want more features than TinyCore.

## How it works

It packs `/` into a squashfs image `rootfs.sfs`. The `bootx64.efi` shim passes the ESP UUID to the Linux kernel's EFI stub over command line, which is then used by the init script to locate `rootfs.sfs` and the LUKS home. Afterwards it's copied to ramfs and mounted. Finally an overlayfs is mounted over that and booted.

The kernel command line is monkey-patched into the `bootx64.efi` executable.

The scripts drop grub configuration and `/etc/fstab` to discourage the immutable system from screwing up itself.

To support `remount-home`, the user home folders are symlinked into `/home` to better support remounting the underlying storage.
