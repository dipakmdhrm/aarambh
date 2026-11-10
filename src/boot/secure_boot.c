#include <efi.h>
#include <efilib.h>

#include "boot/secure_boot.h"

typedef struct {
    EFI_STATUS (__attribute__((sysv_abi)) *verify)(void *buffer, UINT32 size);
    void *hash;
    void *context;
} ShimLock;

typedef struct SecurityArch SecurityArch;
typedef struct Security2Arch Security2Arch;

typedef EFI_STATUS (EFIAPI *SecurityAuthenticate)(const SecurityArch *self, UINT32 status,
                                                  const EFI_DEVICE_PATH *file);
typedef EFI_STATUS (EFIAPI *Security2Authenticate)(const Security2Arch *self,
                                                   const EFI_DEVICE_PATH *file, void *buffer,
                                                   UINTN size, BOOLEAN boot_policy);

struct SecurityArch {
    SecurityAuthenticate authenticate;
};

struct Security2Arch {
    Security2Authenticate authenticate;
};

static EFI_GUID shim_lock_guid = {
    0x605dab50, 0xe046, 0x4300, { 0xab, 0xb6, 0x3d, 0xd8, 0x10, 0xdd, 0x8b, 0x23 }
};

static EFI_GUID security_guid = {
    0xa46423e3, 0x4617, 0x49f1, { 0xb9, 0xff, 0xd1, 0xbf, 0xa9, 0x11, 0x58, 0x39 }
};

static EFI_GUID security2_guid = {
    0x94ab2f58, 0x1438, 0x4ef1, { 0x91, 0x52, 0x18, 0x94, 0x1a, 0x3a, 0x0e, 0x68 }
};

static ShimLock *shim_lock;

static SecurityArch *security;
static SecurityAuthenticate security_original;
static Security2Arch *security2;
static Security2Authenticate security2_original;

static const void *pending_buffer;
static UINTN pending_size;

static int read_secure_boot_variable(void)
{
    UINT8 *value = LibGetVariable(L"SecureBoot", &EfiGlobalVariable);
    int on;

    if (value == NULL) {
        return 0;
    }

    on = value[0] == 1;
    FreePool(value);
    return on;
}

static int shim_accepts(const void *buffer, UINTN size)
{
    if (buffer == NULL || size == 0 || size > 0xffffffffULL) {
        return 0;
    }

    return shim_lock->verify((void *)buffer, (UINT32)size) == EFI_SUCCESS;
}

static EFI_STATUS EFIAPI security_hook(const SecurityArch *self, UINT32 status,
                                       const EFI_DEVICE_PATH *file)
{
    if (shim_accepts(pending_buffer, pending_size)) {
        return EFI_SUCCESS;
    }

    return security_original(self, status, file);
}

static EFI_STATUS EFIAPI security2_hook(const Security2Arch *self, const EFI_DEVICE_PATH *file,
                                        void *buffer, UINTN size, BOOLEAN boot_policy)
{
    if (shim_accepts(buffer, size)) {
        return EFI_SUCCESS;
    }

    return security2_original(self, file, buffer, size, boot_policy);
}

void secure_boot_init(void)
{
    shim_lock = NULL;

    if (read_secure_boot_variable()) {
        BS->LocateProtocol(&shim_lock_guid, NULL, (void **)&shim_lock);
    }
}

void secure_boot_override(const void *buffer, UINTN size)
{
    if (shim_lock == NULL) {
        return;
    }

    pending_buffer = buffer;
    pending_size = size;

    if (BS->LocateProtocol(&security2_guid, NULL, (void **)&security2) == EFI_SUCCESS) {
        security2_original = security2->authenticate;
        security2->authenticate = security2_hook;
    } else {
        security2 = NULL;
    }

    if (BS->LocateProtocol(&security_guid, NULL, (void **)&security) == EFI_SUCCESS) {
        security_original = security->authenticate;
        security->authenticate = security_hook;
    } else {
        security = NULL;
    }
}

void secure_boot_restore(void)
{
    if (security2 != NULL) {
        security2->authenticate = security2_original;
        security2 = NULL;
    }

    if (security != NULL) {
        security->authenticate = security_original;
        security = NULL;
    }

    pending_buffer = NULL;
    pending_size = 0;
}