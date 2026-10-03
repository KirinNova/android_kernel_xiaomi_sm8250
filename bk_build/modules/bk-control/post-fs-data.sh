#!/system/bin/sh

MODDIR=${0%/*}
export BK_CONTROL_DIR=$MODDIR

setup_miui_keyboard()
{
	BK_DEVICE=$(getprop ro.product.device 2>/dev/null)
	BK_FEATURE_SOURCE=/product/etc/device_features/${BK_DEVICE}.xml
	[ -f "$BK_FEATURE_SOURCE" ] || BK_FEATURE_SOURCE=/product/etc/device_features/alioth.xml
	[ -f "$BK_FEATURE_SOURCE" ] || BK_FEATURE_SOURCE=/product/etc/device_features/nabu.xml
	BK_FEATURE_DIR=/data/adb/bk-kernel/device_features
	BK_FEATURE_FILE=$BK_FEATURE_DIR/${BK_DEVICE:-sm8250}.xml
	BK_FEATURE_TMP=$BK_FEATURE_FILE.tmp

	[ -f "$BK_FEATURE_SOURCE" ] || return 0
	grep -q '<bool name="support_usb_keyboard">true</bool>' \
		"$BK_FEATURE_SOURCE" 2>/dev/null && return 0
	mkdir -p "$BK_FEATURE_DIR" || return 0
	cp -f "$BK_FEATURE_SOURCE" "$BK_FEATURE_TMP" || return 0
	if grep -q 'name="support_usb_keyboard"' "$BK_FEATURE_TMP"; then
		sed -i 's#<bool name="support_usb_keyboard">false</bool>#<bool name="support_usb_keyboard">true</bool>#' \
			"$BK_FEATURE_TMP"
	else
		sed -i '/<bool name="support_iic_keyboard">/i\    <bool name="support_usb_keyboard">true</bool>' \
			"$BK_FEATURE_TMP"
	fi
	mv -f "$BK_FEATURE_TMP" "$BK_FEATURE_FILE" || return 0
	chown 0:0 "$BK_FEATURE_FILE"
	chmod 0644 "$BK_FEATURE_FILE"
	chcon u:object_r:system_file:s0 "$BK_FEATURE_FILE" 2>/dev/null || true
	mount --bind "$BK_FEATURE_FILE" "$BK_FEATURE_SOURCE"
}

setup_ufs_io()
{
	BK_UFS_SCHEDULER=/sys/block/sda/queue/scheduler
	[ -w "$BK_UFS_SCHEDULER" ] || return 0
	grep -qw noop "$BK_UFS_SCHEDULER" 2>/dev/null || return 0
	printf '%s\n' noop > "$BK_UFS_SCHEDULER" 2>/dev/null || true
}

setup_extphone_stub()
{
	BK_EXTPHONE_JAR=$MODDIR/telephony/extphonelib.jar
	BK_EXTPHONE_EMPTY=$MODDIR/telephony/empty
	[ -f "$BK_EXTPHONE_JAR" ] || return 0
	[ -f "$BK_EXTPHONE_EMPTY" ] || return 0
	mount -o bind "$BK_EXTPHONE_JAR" /system_ext/framework/extphonelib.jar
	for BK_EXTPHONE_ODEX in \
		/system_ext/framework/oat/arm64/extphonelib.odex \
		/system_ext/framework/oat/arm64/extphonelib.vdex \
		/system_ext/framework/oat/arm/extphonelib.odex \
		/system_ext/framework/oat/arm/extphonelib.vdex
	do
		[ -e "$BK_EXTPHONE_ODEX" ] || continue
		mount -o bind "$BK_EXTPHONE_EMPTY" "$BK_EXTPHONE_ODEX"
	done
}

rm -f /data/adb/post-fs-data.d/bk-zram-writeback.sh
setup_miui_keyboard
setup_ufs_io
setup_extphone_stub
"$MODDIR/scripts/bk-zram-writeback.sh"
