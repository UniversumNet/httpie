#!/bin/bash

###############################################################################
# START-DATE TRACKING SCRIPT                                                  #
#                                                                             #
# This script automatically reviews Phase 1 work packages and updates their  #
# status based on the presence of start and finish dates. It reflects real-  #
# world progress by mapping dates to status IDs dynamically.                 #
###############################################################################

set -euo pipefail
shopt -s expand_aliases
source ~/.http_aliases

###############################################################################
# CONSTANTS                                                                   #
###############################################################################
PROJECT_ID=25
PAGE_SIZE=100
STATUS_SYSTEM_INSPECTED=16
STATUS_IN_PROGRESS=17
STATUS_NEEDS_START_DATE=1
LOG_FILE="$HOME/httpie/logs/start-date.log"
API_URL="https://openproject.universum.nexus/api/v3"

###############################################################################
# TOKEN CHECK                                                                 #
###############################################################################
ACCESS_TOKEN_FILE="$HOME/httpie/session/oauth-tokens/openproject_access_token"
[[ -f "$ACCESS_TOKEN_FILE" ]] \
  || { echo "[ERROR] ACCESS_TOKEN file missing: $ACCESS_TOKEN_FILE"; exit 1; }
export ACCESS_TOKEN=$(<"$ACCESS_TOKEN_FILE")

###############################################################################
# LOGGING                                                                     #
###############################################################################
mkdir -p "$(dirname "$LOG_FILE")"
exec >>"$LOG_FILE" 2>&1
echo "[RUN] $(date '+%F %T') – start-date-script started"

###############################################################################
# FUNCTION: Fetch work package data by ID                                     #
###############################################################################
fetch_wp_data() {
  local wp_id=$1
  http-get "work_packages/$wp_id"
}

###############################################################################
# MAIN LOGIC: Paginate and update work package start dates                    #
###############################################################################
echo "[INFO] Fetching work packages for project $PROJECT_ID..."
offset=1
while :; do
  response=$(http-get "projects/$PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset")

  count=$(jq '.count' <<< "$response")
  [[ $count -eq 0 ]] && break

  jq -c '._embedded.elements[]' <<< "$response" | while read -r wp; do
    id=$(jq -r '.id' <<< "$wp")
    start_date=$(jq -r '.startDate' <<< "$wp")
    finish_date=$(jq -r '.dueDate' <<< "$wp")
    status_href=$(jq -r '._links.status.href // empty' <<< "$wp")
    lock_version=$(jq -r '.lockVersion' <<< "$wp")
    status_id=$(basename "$status_href")

    update_needed=false
    new_status=""
    action=""

    if [[ "$start_date" != "null" && "$finish_date" != "null" && "$status_id" != "$STATUS_SYSTEM_INSPECTED" ]]; then
      new_status="/api/v3/statuses/$STATUS_SYSTEM_INSPECTED"
      update_needed=true
      action="Set status to 'System Inspected'"

    elif [[ "$start_date" != "null" && "$finish_date" == "null" && ( "$status_id" == "$STATUS_NEEDS_START_DATE" || -z "$status_id" ) ]]; then
      new_status="/api/v3/statuses/$STATUS_IN_PROGRESS"
      update_needed=true
      action="Set status to 'In Progress'"

    elif [[ "$start_date" == "null" && "$finish_date" == "null" && "$status_id" != "$STATUS_NEEDS_START_DATE" ]]; then
      new_status="/api/v3/statuses/$STATUS_NEEDS_START_DATE"
      update_needed=true
      action="Force status to 'Needs Inspection Start Date'"
    fi

    if [[ "$update_needed" == true ]]; then
      echo "[INFO] Updating work package $id - $action"

      json_payload=$(jq -n \
        --arg status_href "$new_status" \
        --argjson lock_version "$lock_version" '{
          lockVersion: $lock_version,
          _links: { status: { href: $status_href } }
        }')

      resp=$(http PATCH "$API_URL/work_packages/$id" \
        "Authorization:Bearer $ACCESS_TOKEN" \
        "Content-Type:application/json" \
        <<< "$json_payload")

      echo "[DEBUG] PATCH response: $resp"
    else
      echo "[SKIP] No update needed for work package $id"
    fi
  done

  (( count < PAGE_SIZE )) && break
  offset=$((offset + PAGE_SIZE))
done
