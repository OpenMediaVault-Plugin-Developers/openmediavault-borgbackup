#!/bin/sh

set -e

. /etc/default/openmediavault
. /usr/share/openmediavault/scripts/helper-functions

SERVICE_XPATH="/config/services/borgbackup"

# Add the 'serves' node that holds borg serve client definitions.
if ! omv_config_exists "${SERVICE_XPATH}/serves"; then
    omv_config_add_node "${SERVICE_XPATH}" "serves" ""
fi

exit 0
