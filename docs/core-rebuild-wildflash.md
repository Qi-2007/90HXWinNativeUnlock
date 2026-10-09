# GA102 源码核心重构记录

2026-10-08：v5.1 已由用户确认实机解锁成功。当前实现与构建步骤见 [核心说明](../native/rebuilt-core/README.md) 和 [项目 README](../README.md)。

## 当前边界

发布核心仅链接八个 C 源文件和六份 GPU 固件数据，不链接原 469dc0c 主机机器码。原对象保留在本地 vendor 目录，供离线差分测试；研究对象不进入运行包。

原对象 SHA-256：b533b7b245ed606c151ca336b9a6bacebe935e3ec478246e879c668a4dd98a6a。

## 关键修正

早期直接编译上游 EFI 源码只生成 efi_main，缺少 Windows 所需的七个导出，不能直接替换本项目核心。随后逐步重写策略、事务、VBIOS、FWSEC、PMU 和 SEC2 booter。

v4 用户报告解锁成功。v5 主机机器码依赖已消除，但实机在 FWSEC 完成后返回 -1001。v5.1 恢复原 managed 路径允许 SEC2 复位前不可访问的顺序，复位后验证有效读回再提交 DMA，并增加阶段日志。新增两种签名的 CPUCTL/HWCFG2/engine 恢复对照，写入、延时、镜像和结果证据匹配原对象。

v5.1 驱动签名 Valid，68 项 GUI 工作流测试及包检查通过。用户随后确认实机解锁成功；未另行声称长时间负载或其他配置已通过。

## 保留资料

源码和测试在 native/rebuilt-core；工具在 tools/build-rebuilt-*.ps1 及相关 Python 脚本。当前签名包与清单位于 build/rebuilt-core/{dma-driver-v5.1,gui-v5.1}，完整运行包位于 dist/CMP90HX-source-v5.1。

旧版本运行包、反汇编临时输出和构建缓存已清理。上游研究源码、固定参考对象、固件及有效测试日志保留。重新构建将生成新的清单，不自动继承旧包的实机验证结论。
