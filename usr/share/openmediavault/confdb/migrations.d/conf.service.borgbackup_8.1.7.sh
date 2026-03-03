#!/bin/sh

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

SERVICE_XPATH="/config/services/borgbackup"

if ! omv_config_exists "${SERVICE_XPATH}/compacts"; then
    omv_config_add_node "${SERVICE_XPATH}" "compacts" ""
fi

# Add weeklyday and monthlyday to existing compact schedules.
xpath="${SERVICE_XPATH}/compacts/compactsched"
xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
    xmlstarlet unesc |
    while read uuid; do
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/weeklyday"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "weeklyday" "1"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/monthlyday"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "monthlyday" "1"
        fi
    done

exit 0
