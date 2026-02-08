#!/bin/sh

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/borgbackup/archives/archive"

hour=${OMV_BORGBACKUP_STARTING_HOUR:-2}
hour2=$(( (hour + 1) % 24 ))

xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
    xmlstarlet unesc |
    while read uuid; do
        # hourly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/hourlymin"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "hourlymin" "5"
        fi
        # daily
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/dailyhour"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "dailyhour" "${hour2}"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/dailymin"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "dailymin" "30"
        fi
        # weekly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/weeklyhour"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "weeklyhour" "${hour2}"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/weeklymin"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "weeklymin" "0"
        fi
        # monthly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/monthlyhour"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "monthlyhour" "${hour}"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/monthlymin"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "monthlymin" "30"
        fi
        # yearly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/yearlyhour"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "yearlyhour" "${hour}"
        fi
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/yearlymin"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "yearlymin" "0"
        fi
    done;

exit 0
