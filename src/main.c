#include <efi.h>
#include <efilib.h>

#include "boot/secure_boot.h"
#include "core/app.h"
#include "efi/fs.h"
#include "efi/system.h"

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system_table)
{
    EFI_STATUS status;

    InitializeLib(image, system_table);

    status = system_init(image);
    if (EFI_ERROR(status)) {
        return status;
    }

    status = fs_init(system_device_handle());
    if (EFI_ERROR(status)) {
        return status;
    }

    secure_boot_init();

    status = app_init();
    if (EFI_ERROR(status)) {
        return status;
    }

    app_run();
    return EFI_SUCCESS;
}