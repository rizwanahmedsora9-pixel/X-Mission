#!/system/bin/sh
# Magisk runs this when the system broadcasts BOOT_COMPLETED (Magisk 24+).
# It is the SECOND, independent door into the gateway: on some ROMs the
# late_start service.sh is dropped or races the boot storm, and that is how
# the phone came up with no listener, no redirect, no admin panel and no
# captive portal after a plain reboot. Everything service.sh starts is
# guarded by pid files and a live HTTP probe, so running both is safe: the
# second caller finds the pages already answering and exits.
MODDIR=${0%/*}
if [ -x /system/bin/sh ]; then
  exec /system/bin/sh "$MODDIR/service.sh"
fi
exec sh "$MODDIR/service.sh"
