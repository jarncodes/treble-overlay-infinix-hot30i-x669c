#!/sbin/sh
MODPATH=${0%/*}
ui_print "Installing ${MODPATH##*/}..."

## Overlay APKs
set_perm_recursive $MODPATH/system/product/overlay 0 0 0755 0644 u:object_r:system_file:s0

ui_print "✔ Module installed successfully!"
