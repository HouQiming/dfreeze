#include "../efi/efi.h"
#include "../efi/efi-bs.h"
#include "../efi/efi-rs.h"
#include "../efi/efi-st.h"
#include "../efi/protocol/efi-dpp.h"
#include "../efi/protocol/efi-lip.h"
//#include "../efi/protocol/efi-fp.h"
//#include "../efi/protocol/efi-sfsp.h"
#include "../efi/protocol/efi-stip.h"
#include "../efi/protocol/efi-stop.h"

#define NULL ((void*)0)

CHAR8 g_kernel_command8[512]=" KRNLCMD iommu=on intel_iommu=on rd.driver.blacklist=nouveau modprobe.blacklist=nouveau quiet";
CHAR16 g_kernel_command[512];

EFI_HANDLE g_image_handle;
EFI_SYSTEM_TABLE* g_system_table;

EFI_GUID gEfiLoadedImageProtocolGuid=EFI_LOADED_IMAGE_PROTOCOL_GUID;
EFI_GUID gEfiDevicePathProtocolGuid=EFI_DEVICE_PATH_PROTOCOL_GUID; 

void print(CHAR16* s){
	g_system_table->ConOut->OutputString(g_system_table->ConOut, s);
}

void abort(CHAR16* s){
	print(s);
	g_system_table->RuntimeServices->ResetSystem(EfiResetShutdown,0,0,NULL);
}

CHAR16* wstrcpy(CHAR16* a,CHAR16* b){
	while(*b){
		*a=*b;
		a++;
		b++;
	}
	*a=0;
	return a;
}

void _memcpy(void* a,void* b,uint64_t n){
	uint8_t* p0=(uint8_t*)a;
	uint8_t* p1=(uint8_t*)b;
	uint64_t i;
	for(i=0;i<n;i++){
		p0[i]=p1[i];
	}
}

void PrintNumber(uint64_t n){
	CHAR16 s[32];
	int32_t p;
	int32_t q;
	p=0;
	for(;;){
		s[p]=n%10+48;
		n/=10;
		p+=1;
		if(!n||p>=24){break;}
	}
	q=0;
	while(q<p-1-q){
		CHAR16 tmp=s[q];
		s[q]=s[p-1-q];
		s[p-1-q]=tmp;
		q+=1;
	}
	wstrcpy(s+p,L"\r\n");
	g_system_table->ConOut->OutputString(g_system_table->ConOut, s);
}

void DumpDevicePath(EFI_DEVICE_PATH_PROTOCOL* dpp){
	for(;;){
		uint64_t lg=(uint8_t)(dpp->Length[0])+((uint32_t)(uint8_t)(dpp->Length[1])<<8);
		print(L"type: ");PrintNumber(dpp->Type);
		print(L"subtype: ");PrintNumber(dpp->SubType);
		print(L"length: ");PrintNumber(lg);
		print((CHAR16*)(dpp+1));print(L"\r\n");
		if(dpp->Type==EFI_END_OF_HARDWARE_DEVICE_PATH){break;}
		dpp=(EFI_DEVICE_PATH_PROTOCOL*)((uint8_t*)dpp+lg);
	}
}

EFI_DEVICE_PATH_PROTOCOL* dpptype(EFI_DEVICE_PATH_PROTOCOL* dpp,uint32_t type){
	for(;;){
		uint64_t lg=(uint8_t)(dpp->Length[0])+((uint32_t)(uint8_t)(dpp->Length[1])<<8);
		if(dpp->Type==type){return dpp;}
		if(dpp->Type==EFI_END_OF_HARDWARE_DEVICE_PATH){return NULL;}
		dpp=(EFI_DEVICE_PATH_PROTOCOL*)((uint8_t*)dpp+lg);
	}
}

void dppcpy(EFI_DEVICE_PATH_PROTOCOL* dpp,EFI_DEVICE_PATH_PROTOCOL* dpp1){
	for(;;){
		uint64_t lg=(uint8_t)(dpp1->Length[0])+((uint32_t)(uint8_t)(dpp1->Length[1])<<8);
		_memcpy(dpp,dpp1,lg);
		if(dpp1->Type==EFI_END_OF_HARDWARE_DEVICE_PATH){break;}
		dpp=(EFI_DEVICE_PATH_PROTOCOL*)((uint8_t*)dpp+lg);
		dpp1=(EFI_DEVICE_PATH_PROTOCOL*)((uint8_t*)dpp1+lg);
	}
}

void dppcat(EFI_DEVICE_PATH_PROTOCOL* dpp,EFI_DEVICE_PATH_PROTOCOL* dpp1){
	for(;;){
		uint64_t lg=(uint8_t)(dpp->Length[0])+((uint32_t)(uint8_t)(dpp->Length[1])<<8);
		if(dpp->Type==EFI_END_OF_HARDWARE_DEVICE_PATH){break;}
		dpp=(EFI_DEVICE_PATH_PROTOCOL*)((uint8_t*)dpp+lg);
	}
	dppcpy(dpp,dpp1);
}

///
/// Hard Drive Media Device Path SubType.
///
#define EFI_MEDIA_HARDDRIVE_DP        0x01

///
/// The Hard Drive Media Device Path is used to represent a partition on a hard drive.
///
typedef struct {
  EFI_DEVICE_PATH_PROTOCOL        Header;
  ///
  /// Describes the entry in a partition table, starting with entry 1.
  /// Partition number zero represents the entire device. Valid
  /// partition numbers for a MBR partition are [1, 4]. Valid
  /// partition numbers for a GPT partition are [1, NumberOfPartitionEntries].
  ///
  UINT32                          PartitionNumber;
  ///
  /// Starting LBA of the partition on the hard drive.
  ///
  UINT64                          PartitionStart;
  ///
  /// Size of the partition in units of Logical Blocks.
  ///
  UINT64                          PartitionSize;
  ///
  /// Signature unique to this partition:
  /// If SignatureType is 0, this field has to be initialized with 16 zeros.
  /// If SignatureType is 1, the MBR signature is stored in the first 4 bytes of this field.
  /// The other 12 bytes are initialized with zeros.
  /// If SignatureType is 2, this field contains a 16 byte signature.
  ///
  UINT8                           Signature[16];
  ///
  /// Partition Format: (Unused values reserved).
  /// 0x01 - PC-AT compatible legacy MBR.
  /// 0x02 - GUID Partition Table.
  ///
  UINT8                           MBRType;
  ///
  /// Type of Disk Signature: (Unused values reserved).
  /// 0x00 - No Disk Signature.
  /// 0x01 - 32-bit signature from address 0x1b8 of the type 0x01 MBR.
  /// 0x02 - GUID signature.
  ///
  UINT8                           SignatureType;
} EFI_HARDDRIVE_DEVICE_PATH;

uint8_t g_buf[65536];
CHAR16 g_hexuuid[64];

EFI_STATUS efi_main(EFI_HANDLE ih, EFI_SYSTEM_TABLE *st) {
	EFI_STATUS status;
	EFI_LOADED_IMAGE_PROTOCOL* my_image;
	EFI_LOADED_IMAGE_PROTOCOL* linux_image;
	EFI_HANDLE ih_linux;
	CHAR16* fn;
	CHAR16* basename;
	uint64_t lg;
	EFI_DEVICE_PATH_PROTOCOL* dp_drive;
	EFI_DEVICE_PATH_PROTOCOL* my_dpp;
	EFI_DEVICE_PATH_PROTOCOL* my_dpp_fn_part;
	EFI_DEVICE_PATH_PROTOCOL* my_dpp_drive_part;
	CHAR16* arg_end;
	uint64_t i;
	//make a bootloader first
	g_image_handle = ih;
	g_system_table = st;
	my_image = NULL;
	status = g_system_table->BootServices->OpenProtocol (
	                g_image_handle,
	                &gEfiLoadedImageProtocolGuid,
	                (VOID **) &my_image,
	                NULL,
	                NULL,
	                EFI_OPEN_PROTOCOL_GET_PROTOCOL
	                );
	if(status!=EFI_SUCCESS){
		abort(L"failed to get my_image\r\n");
		return status;
	}
	status = g_system_table->BootServices->HandleProtocol (my_image->DeviceHandle,&gEfiDevicePathProtocolGuid,(void**)&dp_drive);
	if(status!=EFI_SUCCESS){
		abort(L"failed to get the drive letter\r\n");
		return status;
	}
	//g_system_table->ConOut->OutputString(g_system_table->ConOut, fn);
	my_dpp=(EFI_DEVICE_PATH_PROTOCOL*)g_buf;
	dppcpy(my_dpp,dp_drive);
	my_dpp_fn_part=dpptype(my_dpp,EFI_END_OF_HARDWARE_DEVICE_PATH);
	dppcat(my_dpp,my_image->FilePath);
	my_dpp_drive_part=dpptype(my_dpp,EFI_MEDIA_DEVICE_PATH);
	if(my_dpp_drive_part->SubType!=EFI_MEDIA_HARDDRIVE_DP){
		abort(L"failed to find drive dpp\r\n");
	}
	if(((EFI_HARDDRIVE_DEVICE_PATH*)my_dpp_drive_part)->SignatureType!=2){
		abort(L"must boot from GPT\r\n");
	}
	{
		int64_t i;
		CHAR16* hex=L"0123456789abcdef";
		UINT8* sig=((EFI_HARDDRIVE_DEVICE_PATH*)my_dpp_drive_part)->Signature;
		UINT8 ord[16]={3,2,1,0, 5,4, 7,6, 8,9, 10,11,12,13,14,15};
		int64_t p=0;
		for(i=0;i<16;i++){
			g_hexuuid[p++]=hex[sig[ord[i]]>>4];
			g_hexuuid[p++]=hex[sig[ord[i]]&0xf];
			if(i==3||i==5||i==7||i==9){
				g_hexuuid[p++]='-';
			}
		}
		g_hexuuid[p]=0;
	}
	//print(g_hexuuid);
	//print(L"\r\n");
	//abort(L"Done\r\n");
	lg=(uint8_t)(my_dpp_fn_part->Length[0])+((uint32_t)(uint8_t)(my_dpp_fn_part->Length[1])<<8);
	//_memcpy(g_buf,my_dpp_fn_part,lg);
	fn=(CHAR16*)(my_dpp_fn_part+1);
	//PrintNumber((uint8_t)(my_dpp_fn_part->Length[0]));
	//PrintNumber((uint8_t)(my_dpp_fn_part->Length[1]));
	//basename points to the terminating zero, which is inside lg
	basename=fn+((lg-4)>>1)-1;
	//\EFI\BOOT\BOOTX64.EFI
	while(basename-fn>0&&basename[-1]!='\\'){
		basename-=1;
	}
	//lg=(basename+5-fn)*2+4;
	//PrintNumber(lg);
	//my_dpp_fn_part->Length[0]=lg&0xff;
	//my_dpp_fn_part->Length[1]=lg>>8;
	wstrcpy(basename,L"LINUX64.EFI");
	//g_system_table->ConOut->OutputString(g_system_table->ConOut, fn);
	status = g_system_table->BootServices->LoadImage (0,g_image_handle,my_dpp,NULL,0,&ih_linux);
	if(status!=EFI_SUCCESS){
		g_system_table->ConOut->OutputString(g_system_table->ConOut, fn);
		g_system_table->ConOut->OutputString(g_system_table->ConOut, L"\r\n");
		PrintNumber(status-EFI_ERR);
		abort(L"failed to load image\r\n");
		return status;
	}
	status = g_system_table->BootServices->OpenProtocol (
	                ih_linux,
	                &gEfiLoadedImageProtocolGuid,
	                (VOID **) &linux_image,
	                NULL,
	                NULL,
	                EFI_OPEN_PROTOCOL_GET_PROTOCOL
	                );
	if(status!=EFI_SUCCESS){
		abort(L"failed to get linux image info\r\n");
		return status;
	}
	//pass espuuid to help identify the boot disk
	arg_end=(CHAR16*)g_buf;
	arg_end=wstrcpy(arg_end,L" initrd=");
	wstrcpy(basename,L"initrdx.img");
	arg_end=wstrcpy(arg_end,fn);
	arg_end=wstrcpy(arg_end,L" espuuid=");
	arg_end=wstrcpy(arg_end,g_hexuuid);
	for(i=0;g_kernel_command8[i];i++){
		g_kernel_command16[i]=g_kernel_command8[i];
	}
	g_kernel_command16[i]=0;
	arg_end=wstrcpy(arg_end,g_kernel_command16);
	//linux_image->DeviceHandle=my_image->DeviceHandle;
	linux_image->LoadOptions=g_buf;
	linux_image->LoadOptionsSize=(uint8_t*)(arg_end+1)-g_buf;
	//print((CHAR16*)g_buf);
	status = g_system_table->BootServices->StartImage (ih_linux, NULL, NULL);
	abort(L"Linux didn't boot\r\n");
	return EFI_SUCCESS;
}
