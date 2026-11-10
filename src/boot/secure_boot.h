#ifndef AARAMBH_BOOT_SECURE_BOOT_H
#define AARAMBH_BOOT_SECURE_BOOT_H

#include <efi.h>

/*
 * When Secure Boot is on and Aarambh was started by shim, images are checked
 * by shim (db, MOK, vendor certificate, SBAT and dbx) before the firmware's
 * own db check, so kernels signed by the distribution or by the user's MOK
 * key load too. Without shim this does nothing.
 */
void secure_boot_init(void);

void secure_boot_override(const void *buffer, UINTN size);
void secure_boot_restore(void);

#endif