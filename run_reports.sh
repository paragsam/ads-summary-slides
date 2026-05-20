#!/usr/bin/env bash
# run_reports.sh — Orchestrate the TikTok Ads report pipeline.
#
# Usage:
#   ./run_reports.sh                        # run reports due now per their schedule
#   ./run_reports.sh --all                  # run all enabled reports regardless of schedule
#   ./run_reports.sh --report-id <id>       # run one specific report by ID

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_JSON="$SCRIPT_DIR/reports.json"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
step() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]   $*"; }
ok()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $*" >&2; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in jq python3 gws; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "Missing required commands: ${missing[*]}"
        fail "Install them and try again."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
RUN_ALL=false
TARGET_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)        RUN_ALL=true; shift ;;
        --report-id)  TARGET_ID="$2"; shift 2 ;;
        *)            fail "Unknown argument: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
jq_report() {
    # jq_report <id> <filter>  — query a single report by id
    local id="$1" filter="$2"
    jq -r --arg id "$id" ".reports[] | select(.id == \$id) | $filter" "$REPORTS_JSON"
}

append_run() {
    # Append a run entry to runs[] for the given report id
    local id="$1" entry="$2" tmp
    tmp=$(mktemp)
    jq --arg id "$id" \
       --argjson entry "$entry" \
       '(.reports[] | select(.id == $id) | .runs) += [$entry]' \
       "$REPORTS_JSON" > "$tmp" && mv "$tmp" "$REPORTS_JSON"
}

update_last_run() {
    # Replace the last entry in runs[] for the given report id
    local id="$1" entry="$2" tmp
    tmp=$(mktemp)
    jq --arg id "$id" \
       --argjson entry "$entry" \
       '(.reports[] | select(.id == $id) | .runs) |= (.[:-1] + [$entry])' \
       "$REPORTS_JSON" > "$tmp" && mv "$tmp" "$REPORTS_JSON"
}

# ---------------------------------------------------------------------------
# Run one report
# ---------------------------------------------------------------------------
run_report() {
    local id="$1"
    local label advertiser_id start end output_dir drive_folder_id campaign_ids

    label=$(jq_report "$id" ".label")
    advertiser_id=$(jq_report "$id" ".advertiser_id")
    start=$(jq_report "$id" ".date_range.start")
    end=$(jq_report "$id" ".date_range.end")
    output_dir=$(jq_report "$id" ".output_dir")
    drive_folder_id=$(jq_report "$id" ".drive_folder_id")
    campaign_ids=$(jq_report "$id" '.campaign_ids | join(" ")')

    local datestamp triggered_at
    datestamp=$(date '+%Y%m%d')
    triggered_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local base="${SCRIPT_DIR}/${output_dir}${id}_${datestamp}"
    local campaigns_json="${base}_campaigns.json"
    local creatives_json="${base}_creatives.json"
    local pptx_path="${base}.pptx"
    local drive_title="${label} — $(date '+%B %-d, %Y')"

    log "▶  Report: $label ($id)"

    # Mark as running
    append_run "$id" "$(jq -n \
        --arg t "$triggered_at" \
        '{triggered_at:$t,status:"running",campaigns_json:null,creatives_json:null,pptx_path:null,drive_url:null,error:null,error_step:null,error_detail:null}')"

    # ── Step 1: Fetch ──────────────────────────────────────────────────────
    step "Step 1/3 — Fetching TikTok data..."
    local fetch_stderr
    fetch_stderr=$(mktemp)

    if ! python3 "$SCRIPT_DIR/fetch_tiktok_data.py" \
            --advertiser-id "$advertiser_id" \
            --campaign-ids $campaign_ids \
            --start "$start" \
            --end "$end" \
            --out "${base}.json" \
            2>"$fetch_stderr"; then

        local err detail
        detail=$(cat "$fetch_stderr")
        err=$(echo "$detail" | python3 -c \
            'import sys,json; d=json.load(sys.stdin); print(d.get("error","fetch failed"))' \
            2>/dev/null || echo "fetch failed")

        fail "STEP FAILED: fetch_tiktok_data.py"
        fail "  Report  : $label"
        fail "  Error   : $err"
        fail "  Detail  : $detail"
        fail "  Action  : Skipping generate and upload steps."

        update_last_run "$id" "$(jq -n \
            --arg t "$triggered_at" --arg e "$err" --arg ed "$detail" \
            '{triggered_at:$t,status:"failed",error_step:"fetch",error:$e,error_detail:$ed,campaigns_json:null,creatives_json:null,pptx_path:null,drive_url:null}')"
        rm -f "$fetch_stderr"
        return 1
    fi
    rm -f "$fetch_stderr"
    ok "Fetch complete → ${campaigns_json##*/}, ${creatives_json##*/}"

    # ── Step 2: Generate PPTX ─────────────────────────────────────────────
    step "Step 2/3 — Generating PPTX..."
    local gen_stderr
    gen_stderr=$(mktemp)

    if ! python3 "$SCRIPT_DIR/generate_pptx.py" \
            --campaigns "$campaigns_json" \
            --creatives "$creatives_json" \
            --start "$start" \
            --end "$end" \
            --out "$pptx_path" \
            2>"$gen_stderr"; then

        local err detail
        detail=$(cat "$gen_stderr")
        err=$(echo "$detail" | python3 -c \
            'import sys,json; d=json.load(sys.stdin); print(d.get("error","generate failed"))' \
            2>/dev/null || echo "generate failed")

        fail "STEP FAILED: generate_pptx.py"
        fail "  Report  : $label"
        fail "  Error   : $err"
        fail "  Detail  : $detail"
        fail "  Action  : Skipping upload step. JSON data saved locally."

        update_last_run "$id" "$(jq -n \
            --arg t "$triggered_at" --arg e "$err" --arg ed "$detail" \
            --arg cs "$campaigns_json" --arg cr "$creatives_json" \
            '{triggered_at:$t,status:"failed",error_step:"generate",error:$e,error_detail:$ed,campaigns_json:$cs,creatives_json:$cr,pptx_path:null,drive_url:null}')"
        rm -f "$gen_stderr"
        return 1
    fi
    rm -f "$gen_stderr"
    ok "PPTX generated → ${pptx_path##*/}"

    # ── Step 3: Upload to Google Drive ────────────────────────────────────
    step "Step 3/3 — Uploading to Google Drive..."
    local upload_stderr upload_stdout drive_url
    upload_stderr=$(mktemp)
    upload_stdout=$(mktemp)

    if ! gws drive files create \
            --upload "$pptx_path" \
            --name "$drive_title" \
            --parent "$drive_folder_id" \
            >"$upload_stdout" 2>"$upload_stderr"; then

        local err
        err=$(cat "$upload_stderr")

        fail "STEP FAILED: gws drive files create"
        fail "  Report  : $label"
        fail "  Error   : $err"
        fail "  Note    : PPTX saved locally at $pptx_path"

        update_last_run "$id" "$(jq -n \
            --arg t "$triggered_at" --arg e "$err" \
            --arg cs "$campaigns_json" --arg cr "$creatives_json" --arg pp "$pptx_path" \
            '{triggered_at:$t,status:"failed",error_step:"upload",error:$e,error_detail:$e,campaigns_json:$cs,creatives_json:$cr,pptx_path:$pp,drive_url:null}')"
        rm -f "$upload_stderr" "$upload_stdout"
        return 1
    fi

    drive_url=$(grep -oP 'https://[^\s]+' "$upload_stdout" | head -1 || echo "")
    rm -f "$upload_stderr" "$upload_stdout"
    ok "Uploaded to Drive: ${drive_url:-'(URL not captured)'}"

    # ── Success ───────────────────────────────────────────────────────────
    update_last_run "$id" "$(jq -n \
        --arg t "$triggered_at" \
        --arg cs "$campaigns_json" --arg cr "$creatives_json" \
        --arg pp "$pptx_path"    --arg du "$drive_url" \
        '{triggered_at:$t,status:"success",campaigns_json:$cs,creatives_json:$cr,pptx_path:$pp,drive_url:$du,error:null,error_step:null,error_detail:null}')"

    log "✓  Done: $label"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_deps

if [[ ! -f "$REPORTS_JSON" ]]; then
    fail "reports.json not found at $REPORTS_JSON"
    exit 1
fi

# Load .env if present
[[ -f "$SCRIPT_DIR/.env" ]] && set -o allexport && source "$SCRIPT_DIR/.env" && set +o allexport

TOTAL=0
PASSED=0
FAILED=0

# Iterate over enabled reports
while IFS= read -r id; do
    # Filter by --report-id if specified
    if [[ -n "$TARGET_ID" && "$id" != "$TARGET_ID" ]]; then
        continue
    fi

    schedule=$(jq_report "$id" ".schedule")

    # Check schedule (skip if not due and not --all / --report-id)
    if [[ "$RUN_ALL" == false && -z "$TARGET_ID" ]]; then
        if ! python3 "$SCRIPT_DIR/check_schedule.py" "$schedule" 2>/dev/null; then
            continue
        fi
    fi

    TOTAL=$((TOTAL + 1))
    if run_report "$id"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi

done < <(jq -r '.reports[] | select(.enabled == true) | .id' "$REPORTS_JSON")

# Summary
if [[ $TOTAL -eq 0 ]]; then
    log "No reports due at this time."
else
    log "Summary: $TOTAL report(s) run — $PASSED succeeded, $FAILED failed."
    [[ $FAILED -gt 0 ]] && exit 1
fi
