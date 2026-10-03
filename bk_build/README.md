# bkk-control for Xiaomi SM8250 (SDM865 / SDM870)

bkk-control 是专为 Xiaomi SM8250 系列（Redmi K40 / POCO F3 / Xiaomi 10 / 10 Pro 等）与高通平台定制的核心控制与性能优化套件（支持 KernelSU / Magisk / APatch 模块形式运行），由 4.14 bk-Kernel 移植并完整适配 Linux 4.19 内核。

---

## 模块特性与架构

- **bkk-control (KernelSU / Magisk Companion Module)**:
  - 核心控制服务位于 `bk_build/modules/bk-control/`。
  - 包含原生 aarch64 优化程序（`bk-zram-setup` 与 `bk-keyboard-monitor`）。
  - 内置 WebUI 控制面板（Kotlin Compose Multiplatform 移植版，支持 MiUIX 主题与深色模式切换）。
  - 内置免 root 诊断日志导出工具（`bkk-log-exporter.apk`）。

- **动态调频与性能策略 (`bk-reburnout.sh`)**:
  - 针对 SM8250 三丛集架构（1× Prime Cortex-A77 @ 3.2GHz, 3× Gold Cortex-A77 @ 2.42GHz, 4× Silver Cortex-A55 @ 1.8GHz）进行了精确的 cpuset 与线程亲和性调度优化。
  - `Re.burnout-mode`：高负载下自动释放 CPU、GPU (Adreno 650)、UFS 3.1、DDR、LLCC 及总线频点潜能；低负载或高温（80℃）自动平滑回退，保护电池与硬件寿命。
  - 自动检测并适配 Linux 4.19 及 4.14 内核版本。

- **ZRAM 回写与内存优化 (`bk-zram-writeback.sh` & `bk-zram-setup.c`)**:
  - 配置基于 `/data/per_boot` 的 zram backing device 循环存储回路。
  - Direct I/O 与自适应每日写入预算限制，大幅降低闪存寿命损耗。
  - 灭屏时自动将不可压缩页与闲置页回写至 backing 存储，保持前台可用物理内存充裕。

- **多机型动态设备兼容 (`post-fs-data.sh`)**:
  - 自动根据 `ro.product.device` 属性动态加载并绑定机型设备特征文件（如 `alioth.xml`、`umi.xml`、`cmi.xml` 等）。
  - 自动优化 UFS I/O 调度器并绑定 telephony stub。

---

## 构建与打包

独立编译与打包模块：

```bash
./bk_build/build-module.sh
```

- 该脚本将使用 Clang 工具链编译 aarch64 原生 helper 二进制，验证模块目录完整性，并自动生成校验合格的 `bkk-control-1.3-<TIMESTAMP>.zip`。
- 安装方式：直接在 KernelSU / Magisk / APatch 管理器中刷入生成的模块 ZIP 即可。
