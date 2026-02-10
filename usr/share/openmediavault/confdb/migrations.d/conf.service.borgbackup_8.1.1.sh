#!/bin/sh

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

xpath="/config/services/borgbackup/archives/archive"

xmlstarlet sel -t -m "${xpath}" -v "uuid" -n ${OMV_CONFIG_FILE} |
    xmlstarlet unesc |
    while read uuid; do
        hourly=$(omv_config_get "${xpath}[uuid='${uuid}']/hourly")
        daily=$(omv_config_get "${xpath}[uuid='${uuid}']/daily")
        weekly=$(omv_config_get "${xpath}[uuid='${uuid}']/weekly")
        monthly=$(omv_config_get "${xpath}[uuid='${uuid}']/monthly")
        yearly=$(omv_config_get "${xpath}[uuid='${uuid}']/yearly")

        hourlyenable=0
        dailyenable=0
        weeklyenable=0
        monthlyenable=0
        yearlyenable=0

        # enable most frequent period that is enabled
        if [ ${hourly} -gt 0 ]; then
            hourlyenable=1
        elif [ ${daily} -gt 0 ]; then
            dailyenable=1
        elif [ ${weekly} -gt 0 ]; then
            weeklyenable=1
        elif [ ${monthly} -gt 0 ]; then
            monthlyenable=1
        elif [ ${yearly} -gt 0 ]; then
            yearlyenable=1
        fi

        # hourly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/hourlyenable"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "hourlyenable" "${hourlyenable}"
        fi
        # daily
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/dailyenable"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "dailyenable" "${dailyenable}"
        fi
        # weekly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/weeklyenable"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "weeklyenable" "${weeklyenable}"
        fi
        # monthly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/monthlyenable"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "monthlyenable" "${monthlyenable}"
        fi
        # yearly
        if ! omv_config_exists "${xpath}[uuid='${uuid}']/yearlyenable"; then
            omv_config_add_key "${xpath}[uuid='${uuid}']" "yearlyenable" "${yearlyenable}"
        fi
    done;

exit 0
