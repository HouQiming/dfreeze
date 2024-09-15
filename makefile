cc = clang-10
cflags_efi = -I efi -target x86_64-pc-win32-coff -ffreestanding -fno-stack-protector -fshort-wchar -mno-red-zone
ld = lld-link-10
lflags_efi = -subsystem:efi_application -nodefaultlib -dll

bootx64.efi: build/bootx64.obj
	@mkdir -p build
	@$(ld) $(lflags_efi) -entry:efi_main $< -out:$@

build/bootx64.obj: boot/bootx64.c
	@mkdir -p build
	@$(cc) $(cflags_efi) -c $< -o $@
