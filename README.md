# KirinNova's Xiaomi SM8250 Kernel

## Warning

**中文:**

内核源码仍在开发中，可能会导致一些不可预料的问题，请谨慎使用。

**English:**

The kernel source code is still under development and may cause some unpredictable problems. Please use it with caution.

## 目录 / Table of Contents

* [简介 / Introduction](https://www.google.com/search?q=%23%E7%AE%80%E4%BB%8B--introduction)
* [特性 / Features](https://www.google.com/search?q=%23%E7%89%B9%E6%80%A7--features)
* [社区 / Community](https://www.google.com/search?q=%23%E7%A4%BE%E5%8C%BA--community)
* [支持的设备 / Supported Devices](https://www.google.com/search?q=%23%E6%94%AF%E6%8C%81%E7%9A%84%E8%AE%BE%E5%A4%87--supported-devices)
* [构建方法 / Build Instructions](https://www.google.com/search?q=%23%E6%9E%84%E5%BB%BA%E6%96%B9%E6%B3%95--build-instructions)
* [快速构建 / Quick Build](https://www.google.com/search?q=%23%E5%BF%AB%E9%80%9F%E6%9E%84%E5%BB%BA--quick-build)
* [手动构建 / Manual Build](https://www.google.com/search?q=%23%E6%89%8B%E5%8A%A8%E6%9E%84%E5%BB%BA--manual-build)



---

## 简介 / Introduction

**中文:**

该 repo 是 [KirinNova  Fork的 (`AstideLabs/android_kernel_xiaomi_sm8250`)](https://www.google.com/search?q=https://github.com/AstideLabs/android_kernel_xiaomi_sm8250)仓库，基于上游源码进行了进一步的深度优化与调整。

**English:**

This repository is based on [KirinNova's fork (`AstideLabs/android_kernel_xiaomi_sm8250`)](https://www.google.com/search?q=https://github.com/AstideLabs/android_kernel_xiaomi_sm8250), featuring further deep optimizations and adjustments built upon the upstream source.

---

## 特性 / Features

**中文:**

本内核支持 [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) & [SuSFS](https://gitlab.com/simonpunk/susfs4ksu)。请自行安装 ReSukiSU 的管理器。NoKernelSU 版本支持应用 Magisk 和 APatch(及他们的分支)。


以下是一些具体的功能:

1. F2FS 开启了 realtime discard 以更好地 TRIM 闪存
2. 支持 EROFS
3. zRAM 支持 LZO、LZ4、LZ4HC、ZSTD 等压缩算法，开启了 ZRAM_WRITEBACK，升级了 LZ4 和 ZSTD
4. 向后移植 5.15 BPF 和 clone3(支持安卓 16/17)
5. 引入 [LE9EC](https://github.com/hakavlad/le9-patch) 以优化内存
6. 向后移植 5.10 的 Binder，MIUI 构建引入来自 xaga 的 millet，AOSP 构建引入 [Re:Kernel](https://github.com/Sakion-Team/Re-Kernel)
7. 修复[电量卡在 1% 的问题](https://github.com/liyafe1997/Xiaomi-fix-battery-one-percent)，并且支持解容
8. 集成 [BBG(Baseband-guard)](https://github.com/vc-teahouse/Baseband-guard)

**English:**

This kernel supports [ReSukiSU](https://github.com/ReSukiSU/ReSukiSU) & [SuSFS](https://gitlab.com/simonpunk/susfs4ksu).

Please install the ReSukiSU Manager by yourself.

The NoKernelSU version supports Magisk and APatch (and their forks).


Feedback is welcome (via Issues or Pull Requests)! Coolapk users can join the discussion in [this post](https://www.coolapk.com/feed/69700122), you can also join my QQ group, or send me private feedback.

Below are some of the key features:

1. F2FS with realtime discard enabled for improved flash TRIM behavior
2. Support for EROFS
3. zRAM with support for multiple compression algorithms, including LZO, LZ4, LZ4HC, and ZSTD, enabled ZRAM_WRITEBACK, upgraded LZ4 and ZSTD
4. Backported BPF from Linux 5.15 and clone3 (Android 16/17 compatible)
5. Introduced [LE9EC](https://github.com/hakavlad/le9-patch) to optimize memory
6. Backported Binder from 5.10; MIUI builds incorporate millet from xaga, while AOSP builds incorporate [Re:Kernel](https://github.com/Sakion-Team/Re-Kernel)
7. Fixes [the issue where the battery percentage gets stuck at 1%](https://github.com/liyafe1997/Xiaomi-fix-battery-one-percent), and supports recognizing higher-capacity replacement batteries
8. Integrate [BBG(Baseband-guard)](https://github.com/vc-teahouse/Baseband-guard)


---

## 支持的设备 / Supported Devices

| 设备代号 / Codename | 设备名称 / Device Name |
| --- | --- |
| alioth | Redmi K40 / POCO F3 / Xiaomi 11X |

---

## 构建方法 / Build Instructions

### 快速构建 / Quick Build

**中文:**

1. fork 本仓库
2. 进入 **Actions**
3. 找到 `Build Kernel`，点击 `Run workflow` 并选择必要内容

**English:**

1. Fork this repo
2. Go to **Actions**
3. Find `Build Kernel`, click `Run workflow`, and select the necessary options

---

### 手动构建 / Manual Build

**中文:**

1. 准备基本构建环境。
需要常用工具链 `git`、`make`、`curl`、`bison`、`flex`、`zip` 等，以及一些软件包。
* 在 Debian/Ubuntu:


```
sudo apt install build-essential git curl wget bison flex zip bc cpio libssl-dev ccache tar

```


还需要 `python` (仅有 `python3` 不够)，可安装:
```
sudo apt install python-is-python3

```


* 在 RHEL/RPM 系统:


```
sudo yum groupinstall 'Development Tools'
sudo yum install wget bc openssl-devel ccache tar

```


注意：`build.sh` 中启用了 `ccache`，路径是 `$HOME/.cache/ccache_mikernel`。可修改或删除。
2. 下载 [ZyC-Clang v16](https://github.com/ZyCromerZ/Clang/releases/tag/16.0.6-20260807-release) 工具链:
```
mkdir zyc-clang
cd zyc-clang
wget https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20260807-release/Clang-16.0.6-20260807.tar.gz
tar -zxvf Clang-16.0.6-20260807.tar.gz
cd ..

```


3. 构建:
* 不使用 KernelSU:
```
bash build_kernel.sh alioth TARGET_OS

```


* 使用 KernelSU:
```
bash build_kernel.sh alioth ksu TARGET_OS

```




示例:
* alioth (Redmi K40) 不使用 KernelSU，为 MIUI 编译:
```
bash build_kernel.sh alioth miui

```


* alioth (Redmi K40) 使用 KernelSU，为 MIUI 编译:
```
bash build_kernel.sh alioth ksu miui

```





**English:**

1. Prepare the build environment.
You need `git`, `make`, `curl`, `bison`, `flex`, `zip`, etc.
* On Debian/Ubuntu:


```
sudo apt install build-essential git curl wget bison flex zip bc cpio libssl-dev ccache tar

```


You also need `python` (not just `python3`):
```
sudo apt install python-is-python3

```


* On RHEL/RPM-based OS:


```
sudo yum groupinstall 'Development Tools'
sudo yum install wget bc openssl-devel ccache tar

```


Note: `ccache` is enabled in `build.sh` (`$HOME/.cache/ccache_mikernel`). You may remove/modify it.
2. Download [ZyC-Clang v16](https://github.com/ZyCromerZ/Clang/releases/tag/16.0.6-20260807-release) toolchain:
```
mkdir zyc-clang
cd zyc-clang
wget https://github.com/ZyCromerZ/Clang/releases/download/16.0.6-20260807-release/Clang-16.0.6-20260807.tar.gz
tar -zxvf Clang-16.0.6-20260807.tar.gz
cd ..

```


3. Build:
* Without KernelSU:
```
bash build_kernel.sh alioth TARGET_OS

```


* With KernelSU:
```
bash build.sh alioth ksu TARGET_OS

```




Example:
* alioth (Redmi K40) without KernelSU, compile for MIUI:
```
bash build_kernel.sh alioth miui

```


* alioth (Redmi K40) with KernelSU, compile for MIUI:
```
bash build_kernel.sh alioth ksu miui

```
