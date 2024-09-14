cc = cc
cflags_efi = -I efi -target x86_64-pc-win32-coff -ffreestanding -fno-stack-protector -fshort-wchar -mno-red-zone
ld = ld
lflags_efi = -subsystem:efi_application -nodefaultlib -dll

bootx64.efi: build/obj/bootx64.obj
	@mkdir -p build
	@$(ld) $(lflags_efi) -entry:efi_main $< -out:$@

build/bootx64.obj : boot/bootx64.c
	@mkdir -p build
	@$(cc) $(cflags_efi) -c $< -o $@
