# 90HXWinNativeUnlock

原 Native 解锁方案的独立项目：命令行 worker、物理 DMA/IOMMU 驱动、原生核心及固定输入。
不包含 GUI 源码，不依赖旧 90HXWindowsUnlock 目录。

- `src/`：原命令行 worker。
- `driver/`：CMP90HXDma 与 IOMMU 驱动源码。
- `native/rebuilt-core/`：重构原生核心和固件；`vendor/` 保留现有固定 .o 输入。
- `tools/`、`docs/`：核心构建、诊断及历史研究说明。
- `build.ps1` 编译原 worker；`build-dma-driver.ps1 -Iommu` 编译 IOMMU 驱动。
- 重构核心的独立构建入口仍为 `tools/build-rebuilt-worker.ps1`、`tools/build-rebuilt-driver.ps1`。

GUI 已独立至 `../90HXWinUnlockConsole`；界面构建和发布哈希更新在 Console 执行。
输出及签名仍沿用 CMP90HX 名称，整理不修改协议或解锁流程。
迁移清单在 `migration/source-copy-manifest.json`；旧目录保留作备份，不复制签名私钥、Git 历史、日志或旧 build/dist。
历史文档可能包含旧的 GUI/发布命令，以上独立项目入口优先。