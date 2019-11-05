#!/bin/bash

set -o errexit -o pipefail

# Don't run anything before this source as it sets PATH here
# shellcheck disable=SC1091
source /etc/profile
# Load device settings from config.json
# shellcheck disable=SC1091
source /usr/sbin/resin-vars

TOKEN="%%TOKEN%%"
TARGET_APP_ID="%%TARGET_APP_ID%%"
FROM_VOLUME="%%FROM_VOLUME%%"
TO_VOLUME="%%TO_VOLUME%%"

setup_logfile() {
    local workdir=$1
    LOGFILE="${workdir}/appmigrator.$(date +"%Y%m%d_%H%M%S").log"
    touch "$LOGFILE"
    tail -f "$LOGFILE" &
    # this is global
    tail_pid=$!
    # redirect all logs to the logfile
    exec 1>> "$LOGFILE" 2>&1
}

finish_up() {
    local failure=$1
    local exit_code=0
    if [ -n "${failure}" ]; then
        echo "Fail: ${failure}"
        exit_code=1
    else
        echo "DONE"
    fi
    sleep 2
    kill $tail_pid || true
    exit ${exit_code}
}

#######################################
# Globals:
#   CONFIG_PATH
# Arguments:
#   var_name: the name of the required entry in config.json
# Returns:
#   var_value: the value of the entry
#######################################
resin_var_manual_load() {
    local var_name=$1
    local var_value

    if [ -f "${CONFIG_PATH}" ]; then
        var_value=$(jq -r ".${var_name}" "${CONFIG_PATH}") || finish_up "Couldn't get ${var_name} from config.json."
        if [ -z "${var_value}" ]; then
            finish_up "Couldn't load ${var_name} key manually."
        fi
    else
        finish_up "Couldn't find the config.json file."
    fi
    echo "${var_value}"
}

main() {
    local current_release_info
    local target_release_info
    local found_from_volume=false
    local found_to_volume=false

    workdir="/mnt/data/appmigrate"
    mkdir -p "${workdir}" && cd "${workdir}"

    # also sets tail_pid
    setup_logfile "${workdir}"

    # Fill in missing global variables, mostly for 2.0.0-rcX OS versions, that have problem with "resin-var"
    if [ -z "${API_ENDPOINT}" ]; then
        API_ENDPOINT=$(resin_var_manual_load "apiEndpoint")
    fi
    if [ -z "${DEVICE_ID}" ]; then
        DEVICE_ID=$(resin_var_manual_load "deviceId")
    fi

    # Application ID check
    APPLICATION_ID=$(curl --silent --fail --retry 5 -X GET \
    "${API_ENDPOINT}/v4/device(${DEVICE_ID})" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" | jq -r '.d[0].belongs_to__application.__id')
    if [ -z "${APPLICATION_ID}" ]; then
        finish_up "Couldn't get Application ID"
    fi
    if [ "${APPLICATION_ID}" == "${TARGET_APP_ID}" ]; then
        finish_up "Current application is the same as the target."
    fi

    current_release_info=$(curl --silent --fail --retry 5 -X GET \
    "${API_ENDPOINT}/v4/release?\$filter=belongs_to__application%20eq%20${APPLICATION_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN") || finish_up "Couldn't get release data."
    # If the user has no access to the app, the reply will be empty
    local -a current_volumes=()
    while IFS='' read -r volume; do
        current_volumes+=("$volume")
    done < <(echo "${current_release_info}" | jq -r '.d[0].composition.volumes | keys[]')
    if [ ${#current_volumes[@]} -eq 0 ]; then
        finish_up "Could not extract current volumes."
    fi

    echo "Current volumes:"
    for v in "${current_volumes[@]}"; do
        echo -n "$v"
        if [ "${v}" == "${FROM_VOLUME:=resin-data}" ]; then
            found_from_volume=true
            echo " (selected)"
        else
            echo
        fi
    done
    if [ "${found_from_volume}" != "true" ]; then
        finish_up "Couldn't select volume to back up from."
    fi

    target_release_info=$(curl --silent --fail --retry 5 -X GET \
    "${API_ENDPOINT}/v4/release?\$filter=belongs_to__application%20eq%20${TARGET_APP_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN") || finish_up "Couldn't get release data."
    # If the user has no access to the app, the reply will be empty
    local -a target_volumes=()
    while IFS='' read -r volume; do
        target_volumes+=("$volume")
    done < <(echo "${target_release_info}" | jq -r '.d[0].composition.volumes | keys[]')
    if [ ${#target_volumes[@]} -eq 0 ]; then
        finish_up "No volumes extracted to migrate to."
    fi

    if [ -z "${TO_VOLUME}" ] && [ ${#target_volumes[@]} -eq 1 ]; then
        echo "Only one target volume, selecting that since no target volume was specified"
        TO_VOLUME="${target_volumes[0]}"
    fi
    echo "Target app volumes:"
    for v in "${target_volumes[@]}"; do
        echo -n "$v"
        if [ "${v}" == "${TO_VOLUME}" ]; then
            found_to_volume=true
            echo " (selected)"
        else
            echo
        fi
    done
    if [ "${found_to_volume}" != "true" ]; then
        finish_up "Couldn't select volume to back up to."
    fi

    echo "Stopping supervisor and user application"
    systemctl stop resin-supervisor || true
    if command balena >/dev/null 2>&1 ; then
        ENGINE="balena"
    else
        ENGINE="docker"
    fi
    # shellcheck disable=SC2046
    $ENGINE rm -f $($ENGINE ps -a -q) 2>/dev/null || true

    # Pre-backup clean just in case
    rm -rf "./backup" || finish_up "Couldn't clear temporary backup location."
    mkdir -p ./backup || finish_up "Couldn't create temporary backup location."
    rm -rf /mnt/data/backup.tgz || finish_up "Couldn't clear up backup file location."

    echo "Backing up."
    cp -r "/var/lib/docker/volumes/${APPLICATION_ID}_${FROM_VOLUME}/_data/" "./backup/${TO_VOLUME}/" || finish_up "Couldn't copy data from docker volume ${APPLICATION_ID}_${FROM_VOLUME}."
    # The command required like this for the way supervisor extraction works, needing "." being present in the archive as root folder
    tar -czvf /mnt/data/backup.tgz  -C backup . || finish_up "Couldn't create backup file."
    rm -rf "./backup" || finish_up "Couldn't clear temporary backup location after backup file creation."

    echo "Moving device to new application."
    curl --silent --fail --retry 10 -X PATCH \
    "${API_ENDPOINT}/v4/device(${DEVICE_ID})" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    --data '{ "belongs_to__application": "'"${TARGET_APP_ID}"'" }' || finish_up "Failed to move device to the new app, ID ${TARGET_APP_ID}"

    systemctl restart resin-supervisor || finish_up "Supervisor restart didn't work."
    sleep 10 # Let the restart commence
    local i=0
    while ! $ENGINE ps | grep -q resin_supervisor ; do
      sleep 1
      i=$((i+1))
      if [ $i -gt 60 ] ; then
        finish_up "Supervisor container didn't come up before timeout"
      fi
    done

    echo "Finished"

    finish_up
}

(
  # Check if already running and bail if yes
  flock -n 99 || (echo "Already running script..."; exit 1)
  main
) 99>/tmp/appmigrator.lock
# Proper exit, required due to the locking subshell
exit $?
