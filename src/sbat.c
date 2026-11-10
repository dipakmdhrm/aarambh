#define SBAT_CSV                                                                  \
    "sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\n" \
    "aarambh,1,Aarambh,aarambh," AARAMBH_VERSION ",https://github.com/NarkAgni/aarambh\n"

const char sbat[sizeof(SBAT_CSV) - 1] __attribute__((section(".sbat"), used, aligned(4096))) = SBAT_CSV;