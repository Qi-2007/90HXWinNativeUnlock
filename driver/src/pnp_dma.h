/* Experimental function-driver backend. It replaces, rather than filters,
 * the NVIDIA function driver. Never acquire an adapter on a foreign PDO or
 * steal/detach an existing IOMMU domain. HAL owns the common-buffer mapping.
 * Buffers/adapter/PDO references survive until reboot, including quarantine. */
typedef struct _CMP_PNP_EXTENSION {
    PDEVICE_OBJECT Lower, Pdo;
    IO_REMOVE_LOCK RemoveLock;
} CMP_PNP_EXTENSION;
static PDEVICE_OBJECT ControlDevice, PnpDevice;
static PDMA_ADAPTER PnpAdapter;
static ULONG PnpStage, PnpLastStatus, PnpPdoFlags, PnpLowerFlags, PnpLastIrql;
static NTSTATUS PnpTrace(ULONG stage, NTSTATUS status)
{
    PnpLastStatus = (ULONG)status; PnpLastIrql = KeGetCurrentIrql(); PnpStage = stage;
    DbgPrintEx(DPFLTR_IHVDRIVER_ID, DPFLTR_INFO_LEVEL,
        "CMP90HX PnP stage=%lu status=0x%08lx PDOflags=0x%08lx lowerFlags=0x%08lx\n",
        stage, (ULONG)status, PnpPdoFlags, PnpLowerFlags);
    return status;
}
static NTSTATUS PnpReleaseCompletion(PDEVICE_OBJECT device, PIRP irp, PVOID context)
{
    CMP_PNP_EXTENSION *ext = (CMP_PNP_EXTENSION *)context;
    UNREFERENCED_PARAMETER(device);
    if (irp->PendingReturned) IoMarkIrpPending(irp);
    IoReleaseRemoveLock(&ext->RemoveLock, irp);
    return STATUS_CONTINUE_COMPLETION;
}
static NTSTATUS PnpPass(CMP_PNP_EXTENSION *ext, PIRP irp, BOOLEAN power)
{
    IoCopyCurrentIrpStackLocationToNext(irp);
    IoSetCompletionRoutine(irp, PnpReleaseCompletion, ext, TRUE, TRUE, TRUE);
    if (power) { PoStartNextPowerIrp(irp); return PoCallDriver(ext->Lower, irp); }
    return IoCallDriver(ext->Lower, irp);
}
static NTSTATUS PnpFinish(CMP_PNP_EXTENSION *ext, PIRP irp, NTSTATUS status)
{
    IoReleaseRemoveLock(&ext->RemoveLock, irp);
    return Finish(irp, status, 0);
}
typedef struct _CMP_POWER_WORK {
    PIO_WORKITEM Item;
    PIRP Irp;
} CMP_POWER_WORK;
static VOID PnpPowerWork(PDEVICE_OBJECT device, PVOID context)
{
    CMP_POWER_WORK *work = (CMP_POWER_WORK *)context;
    CMP_PNP_EXTENSION *ext = (CMP_PNP_EXTENSION *)device->DeviceExtension;
    PIRP irp = work->Irp;
    AcquireLock(); PnpReady = FALSE; State = ARENA_QUARANTINED; HardwareCleanup();
    PnpTrace(16, STATUS_DEVICE_NOT_READY); ReleaseLock();
    IoFreeWorkItem(work->Item); ExFreePoolWithTag(work, 'wPMC');
    PnpPass(ext, irp, TRUE); /* remove lock remains held through lower completion */
}
static NTSTATUS PnpQueuePower(PDEVICE_OBJECT device, CMP_PNP_EXTENSION *ext, PIRP irp)
{
    CMP_POWER_WORK *work = (CMP_POWER_WORK *)ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(*work), 'wPMC');
    if (!work) { PoStartNextPowerIrp(irp); return PnpFinish(ext, irp, STATUS_INSUFFICIENT_RESOURCES); }
    work->Item = IoAllocateWorkItem(device); work->Irp = irp;
    if (!work->Item) {
        ExFreePoolWithTag(work, 'wPMC'); PoStartNextPowerIrp(irp);
        return PnpFinish(ext, irp, STATUS_INSUFFICIENT_RESOURCES);
    }
    IoMarkIrpPending(irp);
    IoQueueWorkItem(work->Item, PnpPowerWork, DelayedWorkQueue, work);
    return STATUS_PENDING;
}

static NTSTATUS PnpComplete(PDEVICE_OBJECT device, PIRP irp, PVOID context)
{
    UNREFERENCED_PARAMETER(device); UNREFERENCED_PARAMETER(irp);
    KeSetEvent((PKEVENT)context, IO_NO_INCREMENT, FALSE);
    return STATUS_MORE_PROCESSING_REQUIRED;
}
static NTSTATUS PnpForwardAndWait(PDEVICE_OBJECT lower, PIRP irp)
{
    KEVENT done; NTSTATUS status;
    KeInitializeEvent(&done, NotificationEvent, FALSE);
    IoCopyCurrentIrpStackLocationToNext(irp);
    IoSetCompletionRoutine(irp, PnpComplete, &done, TRUE, TRUE, TRUE);
    status = IoCallDriver(lower, irp);
    if (status == STATUS_PENDING) KeWaitForSingleObject(&done, Executive, KernelMode, FALSE, NULL);
    return irp->IoStatus.Status;
}
static VOID PnpDiscardBuffer(void)
{
    /* Only called before the allocation has been exposed or armed. */
    if (Buffer) PnpAdapter->DmaOperations->FreeCommonBuffer(PnpAdapter,
        CMP_ARENA_BYTES, PnpLogical, Buffer, TRUE);
    Buffer = NULL; PnpLogical.QuadPart = 0; Physical.QuadPart = 0;
}
static NTSTATUS PnpAllocateBuffer(void)
{
    if (!PnpReady || !PnpAdapter) return STATUS_DEVICE_NOT_READY;
    Buffer = PnpAdapter->DmaOperations->AllocateCommonBuffer(PnpAdapter,
        CMP_ARENA_BYTES, &PnpLogical, TRUE);
    if (!Buffer) return STATUS_INSUFFICIENT_RESOURCES;
    /* IOVA zero is valid; physical allocation's 1 MiB lower bound doesn't apply. */
    if ((PnpLogical.QuadPart & (PAGE_SIZE - 1)) ||
        (ULONGLONG)PnpLogical.QuadPart > 0x100000000ULL - CMP_ARENA_BYTES ||
        ((ULONGLONG)PnpLogical.QuadPart < PnpBar + CMP_BAR0_BYTES &&
         PnpBar < (ULONGLONG)PnpLogical.QuadPart + CMP_ARENA_BYTES)) {
        PnpDiscardBuffer(); return STATUS_CONFLICTING_ADDRESSES;
    }
    return STATUS_SUCCESS;
}
static NTSTATUS PnpStart(PDEVICE_OBJECT device, PCM_RESOURCE_LIST resources)
{
    CMP_PNP_EXTENSION *ext = (CMP_PNP_EXTENSION *)device->DeviceExtension;
    DEVICE_DESCRIPTION description; ULONG bus, slot, size, maps, i, j, low;
    BOOLEAN barAssigned = FALSE;
    NTSTATUS status;
    if (!resources || resources->Count != 1 || PnpAdapter) return PnpTrace(6, STATUS_INVALID_DEVICE_STATE);
    status = IoGetDeviceProperty(ext->Pdo, DevicePropertyBusNumber, sizeof(bus), &bus, &size);
    if (!NT_SUCCESS(status) || size != sizeof(bus) || bus > 255)
        return PnpTrace(7, NT_SUCCESS(status) ? STATUS_NOT_SUPPORTED : status);
    status = IoGetDeviceProperty(ext->Pdo, DevicePropertyAddress, sizeof(slot), &slot, &size);
    if (!NT_SUCCESS(status) || size != sizeof(slot) || (slot >> 16) > 31 || (slot & 65535) > 7)
        return PnpTrace(8, NT_SUCCESS(status) ? STATUS_NOT_SUPPORTED : status);
    PnpBdf = (bus << 8) | ((slot >> 16) << 3) | (slot & 7);
    if (PciValue(PnpBdf, 0, 4) != 0x220d10de) return PnpTrace(9, STATUS_NO_SUCH_DEVICE);
    low = PciValue(PnpBdf, 0x10, 4);
    if (!low || low == MAXULONG || (low & 1) || ((low & 6) != 0 && (low & 6) != 4))
        return PnpTrace(10, STATUS_INVALID_DEVICE_STATE);
    PnpBar = low & ~15u;
    if ((low & 6) == 4) PnpBar |= (ULONGLONG)PciValue(PnpBdf, 0x14, 4) << 32;
    for (i = 0; i < resources->Count; ++i) {
        PCM_PARTIAL_RESOURCE_LIST partial = &resources->List[i].PartialResourceList;
        for (j = 0; j < partial->Count; ++j) {
            PCM_PARTIAL_RESOURCE_DESCRIPTOR r = &partial->PartialDescriptors[j];
            if (r->Type == CmResourceTypeMemory && (ULONGLONG)r->u.Memory.Start.QuadPart == PnpBar &&
                r->u.Memory.Length >= CMP_BAR0_BYTES) barAssigned = TRUE;
        }
    }
    if (!barAssigned) return PnpTrace(11, STATUS_DEVICE_CONFIGURATION_ERROR);
    RtlZeroMemory(&description, sizeof(description));
    description.Version = DEVICE_DESCRIPTION_VERSION3;
    description.Master = TRUE; description.Dma32BitAddresses = TRUE;
    description.InterfaceType = PCIBus; description.BusNumber = bus;
    description.DmaWidth = Width32Bits; description.DmaSpeed = Compatible;
    description.MaximumLength = CMP_ARENA_BYTES; description.DmaAddressWidth = 32;
    PnpAdapter = IoGetDmaAdapter(ext->Pdo, &description, &maps);
    if (!PnpAdapter) return PnpTrace(12, STATUS_NOT_SUPPORTED);
    if (!PnpAdapter->DmaOperations ||
        PnpAdapter->DmaOperations->Size < FIELD_OFFSET(DMA_OPERATIONS, FreeCommonBuffer) + sizeof(PFREE_COMMON_BUFFER) ||
        !PnpAdapter->DmaOperations->AllocateCommonBuffer || !PnpAdapter->DmaOperations->FreeCommonBuffer ||
        !PnpAdapter->DmaOperations->PutDmaAdapter) return PnpTrace(13, STATUS_NOT_SUPPORTED);
    PnpReady = TRUE;
    return PnpTrace(14, STATUS_SUCCESS);
}
static NTSTATUS PnpDispatch(PDEVICE_OBJECT device, PIRP irp)
{
    CMP_PNP_EXTENSION *ext = (CMP_PNP_EXTENSION *)device->DeviceExtension;
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    NTSTATUS status;
    status = IoAcquireRemoveLock(&ext->RemoveLock, irp);
    if (!NT_SUCCESS(status)) return Finish(irp, status, 0);
    if (stack->MajorFunction == IRP_MJ_PNP) {
        switch (stack->MinorFunction) {
        case IRP_MN_DEVICE_USAGE_NOTIFICATION:
            if (stack->Parameters.UsageNotification.InPath)
                return PnpFinish(ext, irp, PnpTrace(15, STATUS_NOT_SUPPORTED));
            break;
        case IRP_MN_START_DEVICE:
            PnpTrace(5, STATUS_PENDING);
            irp->IoStatus.Status = STATUS_SUCCESS;
            status = PnpForwardAndWait(ext->Lower, irp);
            if (NT_SUCCESS(status)) {
                AcquireLock(); status = PnpStart(device, stack->Parameters.StartDevice.AllocatedResourcesTranslated); ReleaseLock();
            } else PnpTrace(5, status);
            return PnpFinish(ext, irp, status);
        case IRP_MN_QUERY_STOP_DEVICE:
        case IRP_MN_QUERY_REMOVE_DEVICE:
            AcquireLock(); status = Buffer || Owner ? STATUS_DEVICE_BUSY : STATUS_SUCCESS; ReleaseLock();
            if (!NT_SUCCESS(status)) return PnpFinish(ext, irp, status);
            irp->IoStatus.Status = STATUS_SUCCESS;
            break;
        case IRP_MN_STOP_DEVICE:
        case IRP_MN_SURPRISE_REMOVAL:
        case IRP_MN_REMOVE_DEVICE:
            /* Forced removal can't be vetoed. Disable access, retain backing pages
             * and the adapter reference; never reuse a possibly outstanding DMA. */
            AcquireLock(); PnpReady = FALSE; State = ARENA_QUARANTINED; HardwareCleanup(); ReleaseLock();
            irp->IoStatus.Status = STATUS_SUCCESS;
            if (stack->MinorFunction == IRP_MN_REMOVE_DEVICE) {
                PDEVICE_OBJECT lower = ext->Lower;
                IoReleaseRemoveLockAndWait(&ext->RemoveLock, irp);
                IoSkipCurrentIrpStackLocation(irp); status = IoCallDriver(lower, irp);
                IoDetachDevice(lower); IoDeleteDevice(device);
                return status;
            }
            break;
        }
        return PnpPass(ext, irp, FALSE);
    }
    if (stack->MajorFunction == IRP_MJ_POWER) {
        if (stack->Parameters.Power.Type == DevicePowerState &&
            stack->Parameters.Power.State.DeviceState != PowerDeviceD0) {
            /* Power-resume/remapping is not supported by this experimental backend. */
            if (stack->MinorFunction == IRP_MN_QUERY_POWER) {
                PoStartNextPowerIrp(irp); return PnpFinish(ext, irp, STATUS_DEVICE_BUSY);
            }
            if (stack->MinorFunction == IRP_MN_SET_POWER) {
                return PnpQueuePower(device, ext, irp);
            }
        }
        return PnpPass(ext, irp, TRUE);
    }
    if (stack->MajorFunction == IRP_MJ_SYSTEM_CONTROL) {
        return PnpPass(ext, irp, FALSE);
    }
    return PnpFinish(ext, irp, STATUS_INVALID_DEVICE_REQUEST);
}
static NTSTATUS PnpAddDevice(PDRIVER_OBJECT driver, PDEVICE_OBJECT pdo)
{
    PDEVICE_OBJECT device; CMP_PNP_EXTENSION *ext; NTSTATUS status;
    PnpPdoFlags = pdo->Flags; PnpTrace(1, STATUS_PENDING);
    if (PnpDevice) return PnpTrace(2, STATUS_NOT_SUPPORTED); /* One target per boot. */
    status = IoCreateDevice(driver, sizeof(CMP_PNP_EXTENSION), NULL, FILE_DEVICE_UNKNOWN, 0, FALSE, &device);
    if (!NT_SUCCESS(status)) return PnpTrace(3, status);
    ext = (CMP_PNP_EXTENSION *)device->DeviceExtension;
    IoInitializeRemoveLock(&ext->RemoveLock, 'rPMC', 0, 0);
    ext->Pdo = pdo; ObReferenceObject(pdo);
    ext->Lower = IoAttachDeviceToDeviceStack(device, pdo);
    if (!ext->Lower) { ObDereferenceObject(pdo); IoDeleteDevice(device); return PnpTrace(4, STATUS_NO_SUCH_DEVICE); }
    PnpLowerFlags = ext->Lower->Flags;
    PnpDevice = device;
    /* Match lower power flags; mutex-taking power work runs on a system worker. */
    device->Flags |= ext->Lower->Flags & (DO_POWER_PAGABLE | DO_POWER_INRUSH);
    device->Flags &= ~DO_DEVICE_INITIALIZING;
    return PnpTrace(4, STATUS_SUCCESS);
}
