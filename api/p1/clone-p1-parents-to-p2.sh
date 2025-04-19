#!/usr/bin/env bash
#
# clone‑p1‑parents‑to‑p2.sh  ── Phase‑1 → Phase‑2 parent sync
#

set -euo pipefail
shopt -s expand_aliases
source ~/.http_aliases                      # brings in http‑get / http‑post

###############################################################################
# CONSTANTS                                                                   #
###############################################################################
API_URL_ROOT="https://openproject.universum.nexus/api/v3"
PHASE_1_PROJECT_ID=25           # (Phase‑1) Inspection
PHASE_2_PROJECT_ID=27           # (Phase‑2) Review & Discuss
TYPE_SYSTEM_P2=22               # (Phase-2) System (P2)
TYPE_SUBSYSTEM_P2=32            # (Phase-2) Sub-System (P2)
DEFAULT_P2_STATUS_ID=15         # (Status) Needs Team Discussion
MAPPING_FILE="$HOME/httpie/session/p1_to_p2_parents.json"
LOG_FILE="$HOME/httpie/logs/clone-parents.log"
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
echo "[RUN] $(date '+%F %T') – clone‑p1‑parents started"

###############################################################################
# FILTER: Triggered Inspection Items                                          #
###############################################################################
FILTERS=$(jq -nc '
  [
    {"status_id": {"operator": "=", "values": ["14","6","4"]}}, # Repair/Maint/Defect
    {"type_id":   {"operator": "=", "values": ["11"]}}          # Inspection Item (P1)
  ]' | jq -sRr @uri)

###############################################################################
# MAIN LOOP                                                                   #
###############################################################################
declare -A P2_MAP               # P1 sub‑system ID  →  P2 sub‑system ID
offset=1

while :; do
  resp=$(http-get \
          "projects/$PHASE_1_PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$offset&filters=$FILTERS")

  count=$(jq '.count' <<<"$resp")
  [[ $count -eq 0 ]] && break

  mapfile -t items < <(jq -c '._embedded.elements[]' <<<"$resp")
  for item in "${items[@]}"; do
    wp_parent_href=$(jq -r '._links.parent.href // empty' <<<"$item")
    [[ -z "$wp_parent_href" ]] && continue            # item without parent → skip

    ############### Phase‑1 Sub‑System & System ################################
    sub_json=$(http-get "${wp_parent_href#/api/v3/}")
    sub_id=$(jq -r '.id'          <<<"$sub_json")
    sub_subject=$(jq -r '.subject'<<<"$sub_json")
    sub_desc=$(jq -r '.description.raw // ""'<<<"$sub_json")
    sys_href=$(jq -r '._links.parent.href'<<<"$sub_json")

    sys_json=$(http-get "${sys_href#/api/v3/}")
    sys_id=$(jq -r '.id'          <<<"$sys_json")
    sys_subject=$(jq -r '.subject'<<<"$sys_json")
    sys_desc=$(jq -r '.description.raw // ""'<<<"$sys_json")

    ############### ensure System (P2) exists ##################################
    search_sys=$(http-get "projects/$PHASE_2_PROJECT_ID/work_packages?pageSize=100")
    sys_p2_id=$(jq -r --arg subj "$sys_subject" '
        ._embedded.elements[]
        | select(.subject==$subj and ._links.type.href=="/api/v3/types/22")
        | .id' <<<"$search_sys" | head -n1)          # ← add head -n1
    sys_p2_id=${sys_p2_id//$'\n'/}

    if [[ -z "$sys_p2_id" ]]; then
      payload=$(jq -nc \
        --arg subj "$sys_subject" \
        --arg desc "$sys_desc" \
        --arg type "/api/v3/types/$TYPE_SYSTEM_P2" \
        --arg stat "/api/v3/statuses/$DEFAULT_P2_STATUS_ID" \
        '{subject:$subj,
          description:{format:"markdown",raw:$desc},
          _links:{
            type:{href:$type},
            status:{href:$stat}
          }}')
      sys_resp=$(http-post "projects/$PHASE_2_PROJECT_ID/work_packages" <<<"$payload")
      sys_p2_id=$(jq -r '.id' <<<"$sys_resp")

      # relate System P2 ↔ System P1
      rel=$(jq -nc --arg from "/api/v3/work_packages/$sys_p2_id" \
                     --arg to   "/api/v3/work_packages/$sys_id" \
         '{_links:{from:{href:$from},to:{href:$to}},type:"relates"}')
      http-post "work_packages/$sys_p2_id/relations" <<<"$rel"
    fi

    ############### ensure Sub‑System (P2) exists ##############################
    search_sub=$(http-get "projects/$PHASE_2_PROJECT_ID/work_packages?pageSize=100")
    sub_p2_id=$(jq -r --arg subj "$sub_subject" --arg par "/api/v3/work_packages/$sys_p2_id" '
        ._embedded.elements[]
        | select(.subject==$subj
                 and ._links.type.href=="/api/v3/types/32"
                 and ._links.parent.href==$par)
        | .id' <<<"$search_sub" | head -n1)          # ← add head -n1
    sub_p2_id=${sub_p2_id//$'\n'/}

    if [[ -z "$sub_p2_id" ]]; then
      payload=$(jq -nc \
        --arg subj "$sub_subject" \
        --arg desc "$sub_desc" \
        --arg type "/api/v3/types/$TYPE_SUBSYSTEM_P2" \
        --arg par  "/api/v3/work_packages/$sys_p2_id" \
        --arg stat "/api/v3/statuses/$DEFAULT_P2_STATUS_ID" \
        '{subject:$subj,
          description:{format:"markdown",raw:$desc},
          _links:{
            type:{href:$type},
            parent:{href:$par},
            status:{href:$stat}
          }}')
      sub_resp=$(http-post "projects/$PHASE_2_PROJECT_ID/work_packages" <<<"$payload")
      sub_p2_id=$(jq -r '.id' <<<"$sub_resp")

      # relate Sub‑System P2 ↔ Sub‑System P1
      rel=$(jq -nc --arg from "/api/v3/work_packages/$sub_p2_id" \
                     --arg to   "/api/v3/work_packages/$sub_id" \
         '{_links:{from:{href:$from},to:{href:$to}},type:"relates"}')
      http-post "work_packages/$sub_p2_id/relations" <<<"$rel"
    fi

    echo "[MAPPING] $sub_id → $sub_p2_id"
    P2_MAP["$sub_id"]="$sub_p2_id"
  done

  [[ $count -lt $PAGE_SIZE ]] && break
  offset=$((offset+PAGE_SIZE))
done

###############################################################################
# WRITE P1→P2 MAP                                                             #
###############################################################################
echo "{" > "$MAPPING_FILE"
for key in "${!P2_MAP[@]}"; do
  echo "  \"$key\": \"${P2_MAP[$key]}\"," >> "$MAPPING_FILE"
done
sed -i '$ s/,$//' "$MAPPING_FILE"
echo "}" >> "$MAPPING_FILE"

echo "[DONE] Mapping saved to: $MAPPING_FILE"

###############################################################################
# CHAIN next step                                                             #
###############################################################################
echo "[CHAIN] Triggering component watcher…"
/home/walt/httpie/scripts/watch-triggered.sh >>"$LOG_FILE" 2>&1
