#!/bin/bash

set -euo pipefail
shopt -s expand_aliases
source ~/.http_aliases

###############################################################################
# TOKEN CHECK                                                                 #
###############################################################################
source "$HOME/httpie/scripts/pre-request/token_manager.sh"

ACCESS_TOKEN_FILE="$HOME/httpie/session/oauth-tokens/openproject_access_token"
if [[ -f "$ACCESS_TOKEN_FILE" ]]; then
  export ACCESS_TOKEN=$(<"$ACCESS_TOKEN_FILE")
else
  echo "[ERROR] ACCESS_TOKEN file missing: $ACCESS_TOKEN_FILE"
  exit 1
fi

###############################################################################
# CONSTANTS                                                                   #
###############################################################################
LOG_FILE="$HOME/httpie/logs/watch-triggered.log"
MAPPING_FILE="$HOME/httpie/session/p1_to_p2_parents.json"
PROCESSED_FILE="$HOME/httpie/session/processed-items.json"
COMPONENT_SCRIPT="$HOME/httpie/api/p1/clone-p1-components-to-p2.sh"
PARENT_SCRIPT="$HOME/httpie/api/p1/clone-p1-parents-to-p2.sh"

###############################################################################
# LOGGING                                                                     #
###############################################################################
mkdir -p "$(dirname "$LOG_FILE")"
[[ ! -f "$PROCESSED_FILE" ]] && echo "{}" > "$PROCESSED_FILE"
[[ ! -f "$MAPPING_FILE" ]] && echo "{}" > "$MAPPING_FILE"

exec >> "$LOG_FILE" 2>&1
echo "[WATCH] $(date '+%F %T') - Checking for triggered components..."

###############################################################################
# Load already-processed IDs                                                  #
###############################################################################
declare -A PROCESSED
while read -r key; do
  PROCESSED["$key"]=1
done < <(jq -r 'keys[]' "$PROCESSED_FILE")

###############################################################################
#  Get list of triggered inspection items                                     #
###############################################################################
FILTERS=$(jq -cn '
  [
    {"status_id": {"operator": "=", "values": ["14", "6", "4"]}},
    {"type_id": {"operator": "=", "values": ["11"]}}
  ]' | jq -sRr @uri)

API_URL="https://openproject.universum.nexus/api/v3"
PHASE_1_PROJECT_ID=25
response=$(http-get "projects/$PHASE_1_PROJECT_ID/work_packages?pageSize=100&filters=$FILTERS")

mapfile -t WPS < <(jq -c '._embedded.elements[]' <<< "$response")
[[ ${#WPS[@]} -eq 0 ]] && echo "[IDLE] No triggered items." && exit 0

TRIGGERED_IDS=()

for wp in "${WPS[@]}"; do
  wp_id=$(jq -r '.id' <<< "$wp")
  [[ -n "${PROCESSED[$wp_id]+set}" ]] && continue
  TRIGGERED_IDS+=("$wp_id")
done

if [[ ${#TRIGGERED_IDS[@]} -eq 0 ]]; then
  echo "[IDLE] Nothing new to process."
  exit 0
fi

###############################################################################
# Verify mapping exists and is non-empty                                      #
###############################################################################
if [[ ! -s "$MAPPING_FILE" || $(jq 'keys | length' "$MAPPING_FILE") -eq 0 ]]; then
  echo "[WARN] No valid parent mapping found. Skipping component cloning cycle."
  exit 0
fi

###############################################################################
# Pass triggered IDs to component cloning script                              #
###############################################################################
echo "[INFO] Cloning ${#TRIGGERED_IDS[@]} triggered components into Phase 2..."
bash "$COMPONENT_SCRIPT" --wp-ids "${TRIGGERED_IDS[@]}"

###############################################################################
# Mark processed                                                              #
###############################################################################
for wp_id in "${TRIGGERED_IDS[@]}"; do
  jq ". + {\"$wp_id\": true}" "$PROCESSED_FILE" > "$PROCESSED_FILE.tmp" && mv "$PROCESSED_FILE.tmp" "$PROCESSED_FILE"
done

echo "[DONE] Watcher cycle complete."
