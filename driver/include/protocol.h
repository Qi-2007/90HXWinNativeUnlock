#ifndef CMP90HX_PROTOCOL_H
#define CMP90HX_PROTOCOL_H
#define CMP_DEVICE_TYPE 0x8337
#define CMP_IOCTL(fn) CTL_CODE(CMP_DEVICE_TYPE, fn, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA)
#define CMP_INFO CMP_IOCTL(0x800)
#define CMP_MAP CMP_IOCTL(0x801)
#define CMP_ARM CMP_IOCTL(0x802)
#define CMP_COMPLETE CMP_IOCTL(0x803)
#define CMP_BIND CMP_IOCTL(0x804)
#define CMP_PCI_READ CMP_IOCTL(0x805)
#define CMP_PCI_WRITE CMP_IOCTL(0x806)
#define CMP_MMIO_READ CMP_IOCTL(0x807)
#define CMP_MMIO_WRITE CMP_IOCTL(0x808)
#define CMP_MAP_IOMMU CMP_IOCTL(0x809)
#define CMP_PNP_STATUS CMP_IOCTL(0x80a)
typedef struct _CMP_PNP_DIAGNOSTICS {
    ULONG Version, Stage, Status, Bdf, PdoFlags, LowerFlags, Irql, Flags;
} CMP_PNP_DIAGNOSTICS;
C_ASSERT(sizeof(CMP_PNP_DIAGNOSTICS) == 32);
/* Version 2 adds scoped hardware access. Existing arena packets stay 40 bytes. */
#define CMP_PROTOCOL_VERSION 2
typedef struct _CMP_TARGET { ULONG Gpu, Bridge; } CMP_TARGET;
typedef struct _CMP_PCI { ULONG Bdf, Offset, Width, Value; } CMP_PCI;
typedef struct _CMP_MMIO { ULONGLONG Address; ULONG Value, Reserved; } CMP_MMIO;
C_ASSERT(sizeof(CMP_TARGET) == 8);
C_ASSERT(sizeof(CMP_PCI) == 16);
C_ASSERT(sizeof(CMP_MMIO) == 16);
#define CMP_ARENA_BYTES (32u * 1024u * 1024u)
typedef struct _CMP_ARENA_INFO {
    ULONG Version;
    ULONG State;
    ULONGLONG Physical;
    ULONGLONG Length;
    ULONGLONG UserAddress;
    ULONGLONG Cookie;
} CMP_ARENA_INFO;
C_ASSERT(sizeof(CMP_ARENA_INFO) == 40);
/* Separate opt-in packet: v2 physical clients must not consume device addresses. */
typedef struct _CMP_IOMMU_INFO {
    CMP_ARENA_INFO Arena;
    ULONGLONG DeviceAddress;
    ULONG GpuBdf;
    ULONG Flags; /* bit 0: common buffer belongs to the real PCI PDO */
} CMP_IOMMU_INFO;
C_ASSERT(sizeof(CMP_IOMMU_INFO) == 56);
#endif
