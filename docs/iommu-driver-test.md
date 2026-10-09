# IOMMU 实验驱动：签名与实机测试

这是独占 90HX 的 PnP 功能驱动实验，不是 NVIDIA 过滤驱动。它通过真实 GPU PDO
调用 `IoGetDmaAdapter` / `AllocateCommonBuffer`，把返回的设备逻辑地址交给 GPU。
映射失败即退出，不回退到直接物理地址 DMA。INF 声明 DMA remapping 支持。
是否在目标机器上真正实现重映射，需要保持 VT-d / 内核 DMA 保护开启并做 GPU 探针确认。

当前状态：WDK 编译和 INF 静态检查通过。2026-10-06，0.1.1 在用户测试机
`02:00.0` 上完成驱动加载及 GSP 双向 DMA 实机探针：设备地址 `0x02000000`，
256 字节输入、用户映射输出及驱动回读均匹配 64/64 个字，状态恢复完成。
探针日志不包含系统 DMA 保护开关状态；保护开启状态仍以测试机器实际设置为准。
随后用户报告同后端完整解锁成功，完整日志尚未留档；NVIDIA 接管尚未验证。
保留 NVIDIA 的方案研究见 [过滤驱动研究](../../90HXWindowsFilterDriverUnlock/docs/nvidia-filter-research.md)。
0.1.1 版取消对 PDO `DO_POWER_PAGABLE` 标志的硬性加载要求；电源隔离在系统工作线程执行。
上一版在此处可能返回“不支持该请求”并出现代码 31。启动失败仍须用下面的诊断确认，不能据此判定已经修复所有代码 31。
普通 PCI DMA remapping 声明不能直接解决 NVIDIA/WDDM 显示驱动兼容问题；
本实验以 System 类功能驱动临时接管 GPU，实际可用性仍以硬件结果为准。

## 构建和签名

仓库根目录执行 `./build-dma-driver.ps1 -Iommu`。
输出目录是 `build/iommu-driver`，包含 SYS、INF、匹配的工作进程和原生核心（如已准备）。
构建不会安装驱动或修改启动配置。

1. 签名 `CMP90HXDmaIommu.sys`。使用当前测试机器认可的内核驱动签名流程。
2. 在签名 SYS 后重新生成 CAT（下面是本机 WDK 路径；目录移到其他机器时修改路径）：

   ```powershell
   & 'H:\Windows Kits\10\bin\10.0.28000.0\x86\Inf2Cat.exe' /driver:'.\build\iommu-driver' /os:10_GE_X64 /uselocaltime
   ```

3. 签名生成的 `CMP90HXDmaIommu.cat`。随后不要再改 SYS 或 INF，否则 CAT 要重新生成和签名。

签名 SYS 不影响已编入驱动的工作进程哈希；**不要再签名、替换或修改包内
`CMP90HXUnlocker.exe`**。如果要签名工作进程，先运行仓库的 `sign-gen2.ps1`，
再重新构建驱动，最后签名 SYS / 生成并签名 CAT。普通 Authenticode 签名有效
并不等于 Windows 内核一定接受，实际仍受机器签名策略约束。

## 安装

保持 VT-d 和内核 DMA 保护开启，退出 GUI，实验期间不运行原自动解锁任务。
该驱动会替换所选 90HX 的 NVIDIA 驱动；不要对其他显示卡安装。

管理员终端可以用 `pnputil /add-driver .\CMP90HXDmaIommu.inf` 把签名包加入驱动仓库。
然后在设备管理器中，对正确的 `PCI\VEN_10DE&DEV_220D` 设备选择
“更新驱动程序 → 浏览我的电脑 → 从可用驱动列表中选取 → 从磁盘安装”，
选择本包 INF，安装 `CMP 90HX IOMMU DMA Test (replaces NVIDIA driver)`。
仅 `pnputil /install` 不保证覆盖更高排名的 NVIDIA 驱动。

不要用现有 `install-dma-driver.ps1` 或 `sc start` 安装这版，它必须绑定 PCI 设备。
设备须正常启动，不能先禁用为 Code 22。只支持单个 segment-0 90HX。
如果安装报告 Code 10 / 签名拒绝，保留错误和 SetupAPI 日志，不进入 GPU 测试。

更新前一版实验驱动时，需要重新签名 SYS、重新生成并签名 CAT，然后安装新 INF 并重启。
本驱动不卸载，只有重启才能确保实际加载新的 SYS。0.1.1 提供不分配内存、不访问 GPU 的诊断：

```powershell
.\CMP90HXUnlocker.exe iommu-status --dma-backend iommu --log iommu-status.log
```

即使 PnP 未正常启动，只要控制设备已创建，该命令也可读启动阶段和 NTSTATUS。
`ready` 是初始化完成；`dma-adapter` 表示 Windows 未返回 DMA adapter；
`duplicate-device-reboot-required` 表示本次启动已有实验设备实例，需要重启。
若控制设备无法打开，查看设备管理器“详细信息 → 问题状态”和
`C:\Windows\INF\setupapi.dev.log` 对应本设备的安装段。

## 实机验证

在包目录打开管理员 PowerShell，按顺序运行。`02:00.0` 要替换为本机 90HX BDF。
这些命令使用配套工作进程，不使用 GUI。先在 `msinfo32` 确认“内核 DMA 保护”为开启。

```powershell
.\CMP90HXUnlocker.exe arena-info --dma-backend iommu --log arena-info.log
.\CMP90HXUnlocker.exe dma-test --dma-backend iommu --log cpu-map.log
.\CMP90HXUnlocker.exe gpu-dma-init-test --dma-backend iommu --bdf 02:00.0 --core .\nvpermissive-core.o --log gpu-dma.log
```

第一步只查询驱动。第二步验证用户映射和驱动 CPU 回读，**不代表 GPU DMA 已通过**。
第三步会显式复位/初始化 GSP 并验证双向 GPU DMA。初始化和 DMA 探针失败时停止，
不自动重试，也不启动完整解锁。发送三份日志及设备管理器状态即可定位映射或 GPU 故障。

双向探针成功后，才继续完整实验解锁：

```powershell
.\CMP90HXUnlocker.exe full-unlock --dma-backend iommu --bdf 02:00.0 --core .\nvpermissive-core.o --out full-unlock.json --log full-unlock.log
```

该命令只验证实验驱动接管时的寄存器/链路结果，**不代表 NVIDIA 已接管或可用 CUDA**。
完整解锁包含桥 SBR，重置后的 IOMMU 映射有效性也是待验证点。

## 当前限制与恢复

映射一旦暴露，arena、DMA adapter 和 PDO 引用保留到本次启动结束；
驱动不卸载，不支持睡眠/休眠后恢复测试，设备掉电或移除会进入隔离状态。
此举避免释放仍可能被 GPU DMA 使用的页面。分配后设备移除请求可能返回忙。
设备地址要求页对齐且完整 32 MiB 位于 4 GiB 以下；IOVA 为零也可有效。Windows 不能满足时
会退出，不通过物理地址兜底。

恢复 NVIDIA 时通过设备管理器重新选择原 NVIDIA 驱动；如果当前启动中报告设备忙，
重启后再切换。需要再次重启就按系统提示执行。重启会清除本次实验解锁状态。
**本版尚未实现保持解锁状态的 NVIDIA 接管流程**，因此当前交付用于验证 IOMMU DMA 路径。

参考：
- [普通设备驱动 DMA remapping 声明](https://learn.microsoft.com/en-us/windows-hardware/drivers/pci/enabling-dma-remapping-for-device-drivers)
- [IoGetDmaAdapter](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-iogetdmaadapter)
- [AllocateCommonBuffer](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nc-wdm-pallocate_common_buffer)
- [WDDM 的 IOMMU DMA remapping](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iommu-dma-remapping)
