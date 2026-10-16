using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CMP90HX
{
    // Driver is explicitly installed/started by the operator. Never stop it on
    // process exit: its pages and crash quarantine belong to this Windows boot.
    sealed class KernelDma : IDisposable
    {
        const uint InfoCode=0x8337e000, MapCode=0x8337e004, ArmCode=0x8337e008, CompleteCode=0x8337e00c;
        internal const uint BindCode=0x8337e010, PciReadCode=0x8337e014, PciWriteCode=0x8337e018,
            MmioReadCode=0x8337e01c, MmioWriteCode=0x8337e020;
        SafeFileHandle handle;
        internal ArenaDescriptor Descriptor;
        internal IntPtr Mapping;
        internal bool Pending;
        readonly bool iommu;
        internal KernelDma(bool map,bool useIommu=false,bool diagnosticsOnly=false)
        {
            iommu=useIommu;
            try {
                handle=Native.CreateFile(iommu?@"\\.\CMP90HXDmaIommu":@"\\.\CMP90HXUnlockNative",0xc0000000,0,IntPtr.Zero,3,0,IntPtr.Zero);
                if(handle.IsInvalid) throw Native.Failure(Marshal.GetLastWin32Error(),"Open CMP90HXUnlockNative (administrator access and matching driver/Gen2 release required; start the driver before this process, then restart Gen2; reboot after driver updates)");
                if(diagnosticsOnly) {
                    if(!iommu || map) throw new ArgumentException("PnP diagnostics require the unmapped IOMMU backend.");
                    return;
                }
                byte[] info=Call(InfoCode,40);
                ValidateInfo(info,false);
                if(map) MapArena();
            } catch { Dispose(); throw; }
        }
        internal string ReadPnpStatus()
        {
            if(!iommu) throw new InvalidOperationException("PnP diagnostics require the IOMMU backend.");
            byte[] info=Call(0x8337e028,32);
            if(BitConverter.ToUInt32(info,0)!=1) throw new IOException("Invalid PnP diagnostic version.");
            string[] stages={"not-added","add-device","duplicate-device-reboot-required","create-fdo","attach-lower",
                "lower-start","start-state","bus-property","slot-property","pci-identity","bar0",
                "assigned-resources","dma-adapter","dma-operations","ready","usage-path-refused","power-quarantine"};
            uint stage=BitConverter.ToUInt32(info,4),bdf=BitConverter.ToUInt32(info,12),flags=BitConverter.ToUInt32(info,28);
            return String.Format("PNP_DMA_STATUS stage={0}({1}) ntstatus=0x{2:x8} bdf={3:x2}:{4:x2}.{5} pdoFlags=0x{6:x8} lowerFlags=0x{7:x8} irql={8} ready={9} adapter={10} buffer={11}",
                stage,stage<stages.Length?stages[stage]:"unknown",BitConverter.ToUInt32(info,8),bdf>>8,(bdf>>3)&31,bdf&7,
                BitConverter.ToUInt32(info,16),BitConverter.ToUInt32(info,20),BitConverter.ToUInt32(info,24),
                (flags&1)!=0,(flags&2)!=0,(flags&4)!=0);
        }
        internal static void ValidateInfo(byte[] info,bool mapped)
        {
            if(info.Length!=40 || BitConverter.ToUInt32(info,0)!=2) throw new IOException("CMP90HXUnlockNative protocol v2 required; sign/install the rebuilt driver and reboot if v1 is already loaded.");
            uint state=BitConverter.ToUInt32(info,4);
            if(state==1 || state==2) throw new RetainedDmaException("DMA_RETAINED: kernel arena is armed/quarantined. Keep GPU disabled and cold boot; no EFI bootstrap is needed for the kernel backend.");
            if(state!=0) throw new IOException("Invalid kernel DMA state.");
            if(!mapped) return;
            ulong physical=BitConverter.ToUInt64(info,8),length=BitConverter.ToUInt64(info,16),address=BitConverter.ToUInt64(info,24);
            if(physical<0x100000 || (physical&4095)!=0 || length!=32UL*1024*1024 || physical>0x100000000UL-length ||
                address==0 || address>Int64.MaxValue-length || (address&4095)!=0 || BitConverter.ToUInt64(info,32)==0)
                throw new IOException("Invalid kernel DMA allocation/map range.");
        }
        byte[] Call(uint code,int size)
        {
            byte[] output=new byte[size]; uint returned;
            if(!Native.DeviceIoControl(handle,code,new byte[0],0,output,size,out returned,IntPtr.Zero))
                throw Native.Failure(Marshal.GetLastWin32Error(),"Kernel DMA IOCTL 0x"+code.ToString("x8"));
            if(returned!=size) throw new IOException("Short kernel DMA response.");
            return output;
        }
        internal void MapArena()
        {
            if(Mapping!=IntPtr.Zero) return;
            if(iommu) {
                byte[] mapped=Call(0x8337e024,56);
                ValidateIommuInfo(mapped);
                Descriptor=new ArenaDescriptor {Length=BitConverter.ToUInt64(mapped,16),Cookie=BitConverter.ToUInt64(mapped,32),
                    DeviceAddress=BitConverter.ToUInt64(mapped,40),GpuBdf=BitConverter.ToUInt32(mapped,48),PnpDma=true};
                Mapping=new IntPtr(checked((long)BitConverter.ToUInt64(mapped,24)));
                return;
            }
            byte[] info=Call(MapCode,40); ValidateInfo(info,true);
            Descriptor=new ArenaDescriptor {Physical=BitConverter.ToUInt64(info,8),Length=BitConverter.ToUInt64(info,16),Cookie=BitConverter.ToUInt64(info,32)};
            Mapping=new IntPtr(checked((long)BitConverter.ToUInt64(info,24)));
        }
        internal static void ValidateIommuInfo(byte[] info)
        {
            if(info.Length!=56) throw new IOException("Invalid PnP DMA packet length.");
            byte[] baseInfo=new byte[40];Buffer.BlockCopy(info,0,baseInfo,0,40);ValidateInfo(baseInfo,false);
            ulong dma=BitConverter.ToUInt64(info,40),length=BitConverter.ToUInt64(info,16),address=BitConverter.ToUInt64(info,24);
            if(BitConverter.ToUInt64(info,8)!=0 || BitConverter.ToUInt32(info,52)!=1 || BitConverter.ToUInt32(info,48)>0xffff ||
                length!=32UL*1024*1024 || (dma&4095)!=0 || dma>0x100000000UL-length ||
                address==0 || address>Int64.MaxValue-length || (address&4095)!=0 || BitConverter.ToUInt64(info,32)==0)
                throw new IOException("Invalid PnP common-buffer device address/mapping; physical fallback is forbidden.");
        }
        internal void RegisterCall(uint code,RegisterIoPacket packet)
        {
            uint returned;
            if(!Native.DeviceIoControl(handle,code,packet.Input,packet.InputLength,packet.Output,packet.OutputLength,out returned,IntPtr.Zero))
                throw Native.Failure(Marshal.GetLastWin32Error(),"CMP90HXUnlockNative IOCTL 0x"+code.ToString("x8"));
            if(returned!=packet.OutputLength) throw new IOException("Short CMP90HXUnlockNative register response.");
        }
        internal void Bind(uint gpu,uint bridge)
        {
            RegisterIoPacket packet=RegisterIoPacket.Current;
            packet.Target(gpu,bridge); RegisterCall(BindCode,packet);
        }
        internal void Acquire() { Call(ArmCode,0); Pending=true; }
        internal void Release() { Call(CompleteCode,0); Pending=false; }
        public void Dispose() { if(handle!=null) { handle.Dispose(); handle=null; } }
    }
}
