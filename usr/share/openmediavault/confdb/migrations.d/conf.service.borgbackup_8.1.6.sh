#!/bin/sh

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/borgbackup/archives/archive"

xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
    xmlstarlet unesc |
    while read uuid; do
        if omv_config_exists "${xpath}[uuid='${uuid}']/noatime"; then
            omv_config_delete "${xpath}[uuid='${uuid}']/noatime"
        fi
    done;

exit 0
