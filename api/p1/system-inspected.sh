#!/bin/bash

###############################################################################
# system-inspected.sh                                                        #
# Marks Sub-Systems and Systems as "System Inspected" if all child WPs       #
# have final statuses. Fetches only type_id 11 (Inspection Items) using      #
# filtered API queries. Tracks processed Inspection Items via JSON.          #
###############################################################################

set -euo pipefail
shopt -s expand_aliases
source ~/.http_aliases

###############################################################################
# CONSTANTS                                                                   #
###############################################################################
PROJECT_ID=25
API_URL="https://openproject.universum.nexus/api/v3"
LOG_FILE="$HOME/httpie/logs/system-inspected.log"
PROCESSED_FILE="$HOME/httpie/session/system-inspected-processed.json"

TYPE_INSPECTION_ITEM=11
TYPE_SUBSYSTEM=31
TYPE_SYSTEM=20

STATUS_SYSTEM_INSPECTED=16
STATUS_NEEDS_START_DATE=1
FINAL_STATUSES=(14 6 4 16 13 7)

###############################################################################
# INIT + TOKEN + LOGGING                                                      #
###############################################################################
source "$HOME/httpie/scripts/pre-request/token_manager.sh"
ACCESS_TOKEN_FILE="$HOME/httpie/session/oauth-tokens/openproject_access_token"
[[ -f "$ACCESS_TOKEN_FILE" ]] || { echo "[ERROR] ACCESS_TOKEN file missing."; exit 1; }
export ACCESS_TOKEN=$(<"$ACCESS_TOKEN_FILE")

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[RUN] $(date '+%F %T') :: system-inspected.sh started"

# Ensure the processed file exists and is a valid JSON object
[[ -f "$PROCESSED_FILE" && -s "$PROCESSED_FILE" ]] || echo '{}' > "$PROCESSED_FILE"

declare -A PROCESSED
while IFS= read -r key; do
  [[ -n "$key" ]] && PROCESSED["$key"]=1
done < <(jq -r 'keys[]?' "$PROCESSED_FILE")
###############################################################################
# PHASE 1: Inspection Items → Sub-Systems                                     #
###############################################################################
echo "[PHASE 1] Scanning Inspection Items with final or null statuses..."

FILTERS=$(jq -cn '
  [
    {"type_id": {"operator": "=", "values": ["11"]}},
    {"project_id": {"operator": "=", "values": ["25"]}}
  ]' | jq -sRr @uri)

response=$(http-get "projects/25/work_packages?pageSize=100&filters=$FILTERS")

echo "$response"

offset=1
PAGE_SIZE=100

declare -A SUBSYSTEM_STATUS_MAP

declare -A TO_TRACK
while :; do
  response=$(http-get "projects/$PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset&filters=$FILTERS")
  total=$(jq -r '.total' <<< "$response")
  jq -c '._embedded.elements[]' <<< "$response" | while read -r wp; do
    wp_id=$(jq -r '.id' <<< "$wp")
    [[ -n "${PROCESSED[$wp_id]+set}" ]] && continue

    status_href=$(jq -r '._links.status.href // empty' <<< "$wp")
    status_id=$(basename "$status_href")
    [[ -z "$status_id" || "$status_id" == "null" ]] && status_id="$STATUS_NEEDS_START_DATE"

    parent_href=$(jq -r '._links.parent.href // empty' <<< "$wp")
    [[ -z "$parent_href" ]] && continue
    parent_id=$(basename "$parent_href")

    SUBSYSTEM_STATUS_MAP["$parent_id"]+=" $status_id"
    TO_TRACK["$wp_id"]=1
  done

  (( offset + PAGE_SIZE > total )) && break
  offset=$((offset + PAGE_SIZE))
done

for sub_id in "${!SUBSYSTEM_STATUS_MAP[@]}"; do
  echo "[DEBUG] Sub-System $sub_id child statuses: ${SUBSYSTEM_STATUS_MAP[$sub_id]}"
  all_final=true

  for sid in ${SUBSYSTEM_STATUS_MAP[$sub_id]}; do
    [[ ! " ${FINAL_STATUSES[*]} " =~ " $sid " ]] && all_final=false && echo "[SKIP] $sub_id has non-final child: $sid" && break
  done

  if [[ "$all_final" == true ]]; then
    echo "[UPDATE] Sub-System $sub_id → 'System Inspected'"
    wp_json=$(http-get "work_packages/$sub_id")
    current_status=$(jq -r '._links.status.href | split("/") | last' <<< "$wp_json")
    lock_version=$(jq -r '.lockVersion' <<< "$wp_json")

    if [[ "$current_status" != "$STATUS_SYSTEM_INSPECTED" ]]; then
      json_payload=$(jq -n \
        --arg status_href "/api/v3/statuses/$STATUS_SYSTEM_INSPECTED" \
        --argjson lock_version "$lock_version" ' {
          lockVersion: $lock_version,
          _links: { status: { href: $status_href } }
        }')

      response=$(http PATCH "$API_URL/work_packages/$sub_id" \
        "Authorization:Bearer $ACCESS_TOKEN" \
        "Content-Type:application/json" <<< "$json_payload")

      if jq -e '._type == "Error"' <<< "$response" >/dev/null; then
        echo "[ERROR] PATCH failed for Sub-System $sub_id"
        jq '.' <<< "$response"
      else
        echo "[SUCCESS] Sub-System $sub_id updated."
      fi
    else
      echo "[UNCHANGED] Sub-System $sub_id already marked."
    fi
  fi

done

# Save processed WP IDs
jq -n --argjson ids "$(printf '%s\n' "${!TO_TRACK[@]}" | jq -R . | jq -s 'reduce .[] as $i ({}; .[$i] = 1)')" '$ids' > "$PROCESSED_FILE"

###############################################################################
# PHASE 2: Sub-Systems → Systems                                              #
###############################################################################
echo "[PHASE 2] Checking Systems..."

FILTERS=$(jq -cn '
  [
    {"status_id": {"operator": "=", "values": ["16"]}},
    {"type_id": {"operator": "=", "values": ["31"]}}
  ]' | jq -sRr @uri)

offset=1
declare -A SYSTEM_STATUS_MAP

while :; do
  response=$(http-get "projects/$PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset&filters=$FILTERS")
  total=$(jq -r '.total' <<< "$response")

  jq -c '._embedded.elements[]' <<< "$response" | while read -r wp; do
    parent_href=$(jq -r '._links.parent.href // empty' <<< "$wp")
    [[ -z "$parent_href" ]] && continue
    parent_id=$(basename "$parent_href")
    SYSTEM_STATUS_MAP["$parent_id"]+=" 16"
  done

  (( offset + PAGE_SIZE > total )) && break
  offset=$((offset + PAGE_SIZE))
done

for sys_id in "${!SYSTEM_STATUS_MAP[@]}"; do
  all_inspected=true
  for sid in ${SYSTEM_STATUS_MAP[$sys_id]}; do
    [[ "$sid" != "$STATUS_SYSTEM_INSPECTED" ]] && all_inspected=false && break
  done

  if [[ "$all_inspected" == true ]]; then
    echo "[UPDATE] System $sys_id → 'System Inspected'"
    wp_json=$(http-get "work_packages/$sys_id")
    current_status=$(jq -r '._links.status.href | split("/") | last' <<< "$wp_json")
    lock_version=$(jq -r '.lockVersion' <<< "$wp_json")

    if [[ "$current_status" != "$STATUS_SYSTEM_INSPECTED" ]]; then
      json_payload=$(jq -n \
        --arg status_href "/api/v3/statuses/$STATUS_SYSTEM_INSPECTED" \
        --argjson lock_version "$lock_version" ' {
          lockVersion: $lock_version,
          _links: { status: { href: $status_href } }
        }')

      response=$(http PATCH "$API_URL/work_packages/$sys_id" \
        "Authorization:Bearer $ACCESS_TOKEN" \
        "Content-Type:application/json" <<< "$json_payload")

      if jq -e '._type == "Error"' <<< "$response" >/dev/null; then
        echo "[ERROR] PATCH failed for System $sys_id"
        jq '.' <<< "$response"
      else
        echo "[SUCCESS] System $sys_id updated."
      fi
    else
      echo "[UNCHANGED] System $sys_id already marked."
    fi
  fi

done

###############################################################################
# DONE                                                                        #
###############################################################################
echo "[COMPLETE] $(date '+%F %T') :: system-inspected.sh finished"
