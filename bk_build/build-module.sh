#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${KERNEL_DIR:-}" ]; then
  KERNEL_DIR=$(CDPATH= cd -- "$KERNEL_DIR" && pwd)
else
  KERNEL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi
OUT_DIR=${OUT_DIR:-$KERNEL_DIR/out}
CLANG_DIR=${CLANG_DIR:-}
MODULE_DIR=$SCRIPT_DIR/modules/bk-control
SOURCE_DIR=$SCRIPT_DIR/modules/bk-control-src

if [ -z "$CLANG_DIR" ] || [ ! -x "$CLANG_DIR/bin/clang" ]; then
  if command -v clang >/dev/null 2>&1; then
    CLANG_BIN=$(command -v clang)
    CLANG_DIR=$(dirname -- "$(dirname -- "$CLANG_BIN")")
  fi
fi

for tool in clang ld.lld llvm-objdump; do
  [ -x "$CLANG_DIR/bin/$tool" ] || command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool not found under $CLANG_DIR/bin or PATH" >&2; exit 2;
  }
done
for file in module.prop customize.sh bkctl action.sh service.sh \
  post-fs-data.sh uninstall.sh skip_mount \
  scripts/bk-reburnout.sh scripts/bk-zram-writeback.sh \
  scripts/bk-wake-guard.sh webroot/index.html webroot/bkControl.js \
  webroot/bridge.js webroot/style.css bin/bkk-log-exporter.apk \
  webroot/composeResources/org.bkkernel.control.generated.resources/drawable/home.svg \
  webroot/composeResources/org.bkkernel.control.generated.resources/drawable/policy.svg \
  webroot/composeResources/org.bkkernel.control.generated.resources/drawable/save_log.svg \
  webroot/composeResources/org.bkkernel.control.generated.resources/font/bk_cjk.ttf \
  telephony/extphonelib.jar telephony/empty; do
  [ -f "$MODULE_DIR/$file" ] || {
    echo "bkk-control input missing: $MODULE_DIR/$file" >&2; exit 2;
  }
done
for file in bk-zram-setup.c bk-keyboard-monitor.c; do
  [ -f "$SOURCE_DIR/$file" ] || {
    echo "bkk-control source missing: $SOURCE_DIR/$file" >&2; exit 2;
  }
done
grep -qx 'id=bk-control' "$MODULE_DIR/module.prop" || {
  echo "unexpected KernelSU module ID" >&2; exit 2;
}
MODULE_VERSION=$(sed -n 's/^version=//p' "$MODULE_DIR/module.prop")
case "$MODULE_VERSION" in
  ''|*[!A-Za-z0-9._-]*)
    echo "invalid bkk-control version: $MODULE_VERSION" >&2; exit 2 ;;
esac
for script in customize.sh bkctl action.sh service.sh post-fs-data.sh \
  uninstall.sh scripts/bk-reburnout.sh scripts/bk-zram-writeback.sh \
  scripts/bk-wake-guard.sh; do
  sh -n "$MODULE_DIR/$script"
done
command -v zip >/dev/null 2>&1 || { echo "zip is required" >&2; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "unzip is required" >&2; exit 2; }

mkdir -p "$OUT_DIR/module-artifacts" "$OUT_DIR/packages"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
ARTIFACTS=$OUT_DIR/module-artifacts
PACKAGE_ROOT=$OUT_DIR/packages
printf '\n[生成] 编译 bkk-control 辅助程序\n'
for name in bk-zram-setup bk-keyboard-monitor; do
  "$CLANG_DIR/bin/clang" --target=aarch64-linux-android \
    -Oz -ffreestanding -fno-builtin -fno-stack-protector \
    -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-pie \
    -nostdlib -static -fuse-ld=lld -Wl,-e,_start -Wl,--build-id=none \
    -Wl,-z,max-page-size=4096 \
    "$SOURCE_DIR/$name.c" -o "$ARTIFACTS/$name"
  "$CLANG_DIR/bin/llvm-objdump" -f "$ARTIFACTS/$name" | \
    grep -F 'architecture: aarch64' >/dev/null || {
      echo "invalid $name architecture" >&2; exit 1;
    }
  chmod 0755 "$ARTIFACTS/$name"
done

stamp=$(date -u +%H%M%S)
ZIP_PATH=$PACKAGE_ROOT/bkk-control-$MODULE_VERSION-$stamp.zip
[ ! -e "$ZIP_PATH" ] || { echo "module package already exists: $ZIP_PATH" >&2; exit 1; }
MODULE_STAGE=$(mktemp -d "$OUT_DIR/.bkk-control.XXXXXX")
trap 'find "$MODULE_STAGE" -depth -delete' 0
printf '\n[打包] 生成独立 KernelSU 模块\n'
cp -a "$MODULE_DIR/." "$MODULE_STAGE/"
cp "$ARTIFACTS/bk-zram-setup" "$MODULE_STAGE/bin/bk-zram-setup"
cp "$ARTIFACTS/bk-keyboard-monitor" "$MODULE_STAGE/bin/bk-keyboard-monitor"
chmod 0755 "$MODULE_STAGE/bkctl" "$MODULE_STAGE/customize.sh" \
  "$MODULE_STAGE/service.sh" "$MODULE_STAGE/post-fs-data.sh" \
  "$MODULE_STAGE/action.sh" "$MODULE_STAGE/uninstall.sh" \
  "$MODULE_STAGE/scripts/bk-reburnout.sh" \
  "$MODULE_STAGE/scripts/bk-zram-writeback.sh" \
  "$MODULE_STAGE/scripts/bk-wake-guard.sh" \
  "$MODULE_STAGE/bin/bk-zram-setup" \
  "$MODULE_STAGE/bin/bk-keyboard-monitor"
(cd "$MODULE_STAGE" && zip -qr9 "$ZIP_PATH" .)

printf '\n[校验] 检查模块内容与辅助程序\n'
unzip -t "$ZIP_PATH" >/dev/null
expected_files=$(cd "$MODULE_STAGE" && find . -type f -print | \
  sed 's#^./##' | LC_ALL=C sort)
actual_files=$(unzip -Z1 "$ZIP_PATH" | grep -v '/$' | LC_ALL=C sort)
[ "$actual_files" = "$expected_files" ] || {
  echo "module package contains unexpected or missing files" >&2; exit 1;
}
unzip -p "$ZIP_PATH" module.prop | grep -Fx 'id=bk-control' >/dev/null || {
  echo "module ID is missing" >&2; exit 1;
}
for name in bk-zram-setup bk-keyboard-monitor; do
  magic=$(unzip -p "$ZIP_PATH" "bin/$name" | \
    dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = 7f454c46 ] || {
    echo "module helper is not ELF: $name" >&2; exit 1;
  }
done
unzip -p "$ZIP_PATH" scripts/bk-reburnout.sh | \
  grep -Fx 'REB_MODE_NAME=Re.burnout-mode' >/dev/null || {
    echo "Re.burnout-mode policy is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" scripts/bk-zram-writeback.sh | \
  grep -F 'HELPER=${BK_CONTROL_DIR:-/data/adb/modules/bk-control}/bin/bk-zram-setup' >/dev/null || {
    echo "zram helper path is incorrect" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" service.sh | \
  grep -F 'org.bkkernel.logexport' >/dev/null || {
    echo "log exporter installer is missing" >&2; exit 1;
  }
unzip -p "$ZIP_PATH" customize.sh | \
  grep -F 'chmod 0755 "$MODPATH/$file"' >/dev/null || {
    echo "KernelSU module permission setup is missing" >&2; exit 1;
  }
require_zip_text()
{
  unzip -p "$ZIP_PATH" "$1" | grep -F "$2" >/dev/null || {
    echo "bkk-control check failed: $1: $2" >&2; exit 1;
  }
}
for required in \
  'reb_config_get swappiness 180' \
  'REB_WB_FLUSH_SAMPLES=12' \
  'REB_WB_DAILY_PAGES=65536' \
  'reb_write /dev/cpuset/foreground/cpus 0-2,4-7' \
  'reb_write /dev/cpuset/top-app/cpus 0-7' \
  'REB_TASK_GUARD=6200' \
  'am kill-all >/dev/null 2>&1 || true' \
  'reb_update_perf_taskset()' \
  'reb_top_thread_is_heavy()' \
  'reb_sample_top_cpu()' \
  'taskset -p f7 "$REB_PROCESS_PID"' \
  'SurfaceSyncGrou|AnimThread*|FsGestureSecond)'; do
  require_zip_text scripts/bk-reburnout.sh "$required"
done
if unzip -p "$ZIP_PATH" scripts/bk-reburnout.sh | \
  grep -F '> /dev/cpuset/' >/dev/null; then
  echo "runtime policy moves framework-managed cpuset membership" >&2; exit 1
fi
if unzip -p "$ZIP_PATH" scripts/bk-reburnout.sh | \
  grep -E 'reb_write "\$REB_UFS/(clkscale_enable|clkgate_enable|auto_hibern8)"' >/dev/null; then
  echo "runtime policy changes the UFS power state machine" >&2; exit 1
fi
for required in 'collect-log)' 'open-log)' 'theme-seed)'; do
  require_zip_text bkctl "$required"
done
require_zip_text post-fs-data.sh '<bool name="support_usb_keyboard">true</bool>'
require_zip_text post-fs-data.sh 'printf '\''%s\n'\'' noop > "$BK_UFS_SCHEDULER"'
require_zip_text post-fs-data.sh 'setup_extphone_stub'
require_zip_text post-fs-data.sh '/system_ext/framework/extphonelib.jar'
require_zip_text webroot/index.html '/internal/colors.css'
(cd "$PACKAGE_ROOT" && sha256sum "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256")

{
  echo "MODULE_ID=bk-control"
  echo "MODULE_VERSION=$MODULE_VERSION"
  echo "KERNEL_COMMIT=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "CLANG=$CLANG_DIR/bin/clang"
  "$CLANG_DIR/bin/clang" --version | head -1
  echo "ZRAM_SETUP_SHA256=$(sha256sum "$ARTIFACTS/bk-zram-setup" | awk '{print $1}')"
  echo "KEYBOARD_MONITOR_SHA256=$(sha256sum "$ARTIFACTS/bk-keyboard-monitor" | awk '{print $1}')"
} > "$ARTIFACTS/build-info.txt"
(cd "$ARTIFACTS" && sha256sum bk-zram-setup bk-keyboard-monitor build-info.txt > SHA256SUMS)
printf '\n[完成] bkk-control 构建与打包通过\n'
printf '[产物] 模块目录 : %s\n' "$ARTIFACTS"
printf '[产物] 安装包   : %s\n' "$ZIP_PATH"
printf '[产物] SHA256   : %s\n' "$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
