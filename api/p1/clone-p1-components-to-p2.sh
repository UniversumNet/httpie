#!/bin/bash

set -euo pipefail           # fail fast
shopt -s expand_aliases
source ~/.http_aliases

###############################################################################
# CONSTANTS                                                                   #
###############################################################################
API_URL="https://openproject.universum.nexus/api/v3"
PHASE_1_PROJECT_ID=25           # (Phase‑1) Inspection
PHASE_2_PROJECT_ID=27           # (Phase‑2) Review & Discuss
DEFAULT_P2_STATUS_ID=15         # (Status) Needs Team Discussion
MAPPING_FILE="$HOME/httpie/session/p1_to_p2_parents.json"
LOG_FILE="$HOME/httpie/logs/clone-components.log"
PAGE_SIZE=100

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
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[RUN] $(date '+%F %T') – clone‑p1‑components started"

###############################################################################
# Load “P1‑sub‑system → P2‑sub‑system” mapping                                #
###############################################################################
[[ -f "$MAPPING_FILE" ]] || { echo "[ERROR] Missing mapping file $MAPPING_FILE"; exit 1; }
declare -A SUBSYSTEM_MAP
while read -r key val; do SUBSYSTEM_MAP["$key"]="$val"; done \
    < <(jq -r 'to_entries[] | "\(.key) \(.value)"' "$MAPPING_FILE")

###############################################################################
# Collect the Phase‑1 work‑package IDs we need to copy                        #
###############################################################################
WP_IDS=()

if [[ ${1-} == "--wp-ids" ]]; then
  shift
  WP_IDS=("$@")
  [[ ${#WP_IDS[@]} -eq 0 ]] && { echo "[INFO] No wp-ids passed – nothing to do"; exit 0; }
  echo "[INFO] Filter mode → ${WP_IDS[*]}"
else
  echo "[INFO] Batch mode – downloading Phase‑1 triggered items…"
  FILTERS=$(jq -cn '
     [
       {"status_id": {"operator":"=", "values":["14","6","4"]}},   # R/R, Maint, Mat Def
       {"type_id":   {"operator":"=", "values":["11"]}}           # Inspection Item (P1)
     ]' | jq -sRr @uri)

  offset=1
  while :; do
    resp=$(http-get "projects/$PHASE_1_PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset&filters=$FILTERS")
    mapfile -t found < <(jq -r '._embedded.elements[].id' <<<"$resp")
    WP_IDS+=("${found[@]}")
    (( $(jq '.count' <<<"$resp") < PAGE_SIZE )) && break
    offset=$((offset + PAGE_SIZE))
  done
fi

[[ ${#WP_IDS[@]} -eq 0 ]] && { echo "[INFO] Nothing found to process"; exit 0; }

###############################################################################
#  Helper: map P1 status → P2 type                                            #
###############################################################################
map_status_to_type () {
  case "$1" in
    14) echo 18 ;;   # (Type)- Repair/Replace (P2)
     6) echo 19 ;;   # (Type)- Maintenance (P2)
     4) echo 27 ;;   # (Type)- Material Defect (P2)
     *) echo 18 ;;   # (Type)- Fallback (treat as Repair/Replace)
  esac
}

###############################################################################
# Phase 1 Component Cloning: Mapping + Type Assignment Based on Status        #
###############################################################################
for wp_id in "${WP_IDS[@]}"; do
  echo "[PROCESS] P1 component $wp_id"
  wp_json=$(http-get "work_packages/$wp_id")

  wp_subject=$(jq -r '.subject'                <<<"$wp_json")
  wp_desc_raw=$(jq -r '.description.raw // ""' <<<"$wp_json")
  status_href=$(jq -r '._links.status.href'    <<<"$wp_json")
  p1_status_id=$(basename "$status_href")

  parent_href=$(jq -r '._links.parent.href // empty' <<<"$wp_json")
  [[ -z "$parent_href" ]] && { echo "[WARN]   No parent – skipping"; continue; }
  p1_sub_id=$(basename "$parent_href")

  p2_sub_id=${SUBSYSTEM_MAP[$p1_sub_id]-}
  [[ -z "$p2_sub_id" ]] && { echo "[WARN]   No mapped P2 sub‑system – skipping"; continue; }

  # decide which **type** the P2 component must be
  type_id=$(map_status_to_type "$p1_status_id")
  type_href="/api/v3/types/$type_id"

  #──────────────── existing check (paginate because P2 project may already be big)
  existing_id=""
  offset=1
  while :; do
    search=$(http-get "projects/$PHASE_2_PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset")
    existing_id=$(jq -r --arg subj "$wp_subject" \
                          --arg type "$type_href" \
                          --arg par "/api/v3/work_packages/$p2_sub_id" '
        ._embedded.elements[]
        | select(.subject==$subj
                 and ._links.type.href==$type
                 and ._links.parent.href==$par)
        | .id' <<<"$search" | head -n1 | tr -d '\n')
    [[ -n "$existing_id" || $(jq '.count' <<<"$search") -lt $PAGE_SIZE ]] && break
    offset=$((offset + PAGE_SIZE))
  done
  if [[ -n "$existing_id" ]]; then
    echo "[SKIP]   Already present in P2 (id $existing_id)"
    continue
  fi

  #──────────────── create the new Phase‑2 component
  echo "[CREATE] $wp_subject  (type $type_id, parent $p2_sub_id)"
  payload=$(jq -n --arg subject "$wp_subject" \
                   --arg desc "$wp_desc_raw" \
                   --arg type "$type_href" \
                   --arg parent "/api/v3/work_packages/$p2_sub_id" \
                   --arg status "/api/v3/statuses/$DEFAULT_P2_STATUS_ID" '
    {
      subject: $subject,
      description:{format:"markdown", raw:$desc},
      _links:{
        type:   {href:$type},
        parent: {href:$parent},
        status: {href:$status}
      }
    }')

  response=$(http POST "$API_URL/projects/$PHASE_2_PROJECT_ID/work_packages" \
                  "Authorization:Bearer $ACCESS_TOKEN" Content-Type:application/json \
                  <<<"$payload")

  new_id=$(jq -r '.id // empty' <<<"$response" | tr -d '\n')
  [[ -z "$new_id" ]] && { echo "[ERROR]  Creation failed – aborting"; exit 1; }

  #──────────────── relate new P2 component → original P1 component
  relation=$(jq -n --arg from "/api/v3/work_packages/$new_id" \
                     --arg to   "/api/v3/work_packages/$wp_id"  \
                     --arg type "relates" \
             '{ _links:{ from:{href:$from}, to:{href:$to} }, type:$type }')

  http POST "$API_URL/work_packages/$new_id/relations" \
       "Authorization:Bearer $ACCESS_TOKEN" Content-Type:application/json \
       <<<"$relation" >/dev/null

  echo "[OK]     P2 component $new_id created & related"
done

echo "[DONE] Clone‑components run completed"
