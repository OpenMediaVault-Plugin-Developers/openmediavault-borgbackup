#!/bin/sh

set -e

. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/borgbackup/archives/archive"

xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
    xmlstarlet unesc |
    while read uuid; do
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/compact"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "compact" "0"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/cthreshold"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "cthreshold" "10"
        fi
    done;

exit 0
