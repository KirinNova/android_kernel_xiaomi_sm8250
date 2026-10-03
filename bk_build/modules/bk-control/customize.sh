#!/system/bin/sh

for file in bkctl service.sh post-fs-data.sh action.sh uninstall.sh \
  scripts/bk-reburnout.sh scripts/bk-zram-writeback.sh \
  scripts/bk-wake-guard.sh bin/bk-zram-setup bin/bk-keyboard-monitor; do
  [ -f "$MODPATH/$file" ] || {
    echo "Missing bkk-control file: $file" >&2
    exit 1
  }
  chmod 0755 "$MODPATH/$file" || exit 1
done
