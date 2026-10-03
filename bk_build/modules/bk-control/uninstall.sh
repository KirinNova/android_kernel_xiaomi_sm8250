#!/system/bin/sh

PID_FILE=/data/adb/bk-kernel/Re.burnout-mode.pid
PID=$(cat "$PID_FILE" 2>/dev/null)
case "$PID" in
	''|*[!0-9]*) ;;
	*) kill "$PID" 2>/dev/null || true ;;
esac
PID_FILE=/data/adb/bk-kernel/bk-keyboard-monitor.pid
PID=$(cat "$PID_FILE" 2>/dev/null)
case "$PID" in
	''|*[!0-9]*) ;;
	*) kill "$PID" 2>/dev/null || true ;;
esac
PID_FILE=/data/adb/bk-kernel/bk-wake-guard.pid
PID=$(cat "$PID_FILE" 2>/dev/null)
case "$PID" in
	''|*[!0-9]*) ;;
	*) kill "$PID" 2>/dev/null || true ;;
esac
rm -f /data/adb/service.d/bk-reburnout.sh
rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh
for BK_EXTPHONE_MOUNT in \
	/system_ext/framework/extphonelib.jar \
	/system_ext/framework/oat/arm64/extphonelib.odex \
	/system_ext/framework/oat/arm64/extphonelib.vdex \
	/system_ext/framework/oat/arm/extphonelib.odex \
	/system_ext/framework/oat/arm/extphonelib.vdex
do
	umount "$BK_EXTPHONE_MOUNT" 2>/dev/null || true
done
pm uninstall --user 0 org.bkkernel.logexport >/dev/null 2>&1 || true
