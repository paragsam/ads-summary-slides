#!/usr/bin/env bash
# run_reports.sh — Orchestrate the TikTok Ads report pipeline.
#
# Runs every hour via cron. Checks the expanded_schedule in reports.json
# to determine which reports are due, then runs fetch → generate → upload.
#
# Usage:
#   ./run_reports.sh                        # run reports due now per expanded_schedule
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
    for cmd in jq python3; do
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

mark_schedule_entry() {
    # Update the status of an expanded_schedule entry by run_at timestamp
    local id="$1" run_at="$2" status="$3" tmp
    tmp=$(mktemp)
    jq --arg id "$id" --arg run_at "$run_at" --arg status "$status" \
       '(.reports[] | select(.id == $id) | .expanded_schedule[] | select(.run_at == $run_at) | .status) |= $status' \
       "$REPORTS_JSON" > "$tmp" && mv "$tmp" "$REPORTS_JSON"
}

# ---------------------------------------------------------------------------
# Schedule helpers
# ---------------------------------------------------------------------------
find_due_entry() {
    # Print the run_at of the first pending expanded_schedule entry due this
    # hour (Pacific Time), or nothing if none is due.
    local id="$1"
    python3 - "$id" "$REPORTS_JSON" <<'PYEOF'
import json, sys
from datetime import datetime
try:
    from zoneinfo import ZoneInfo
    PT = ZoneInfo("America/Los_Angeles")
except ImportError:
    from datetime import timezone, timedelta
    PT = timezone(timedelta(hours=-7))

report_id, reports_json = sys.argv[1], sys.argv[2]
now = datetime.now(PT)

with open(reports_json) as f:
    data = json.load(f)

for r in data.get("reports", []):
    if r.get("id") != report_id:
        continue
    for entry in r.get("expanded_schedule", []):
        if entry.get("status") != "pending":
            continue
        run_at = datetime.fromisoformat(entry["run_at"])
        if run_at.date() == now.date() and run_at.hour == now.hour:
            print(entry["run_at"])
            sys.exit(0)
PYEOF
}

maybe_expand_schedules() {
    # Auto-expand if fewer than 14 days of pending entries remain across all reports.
    local days_ahead
    days_ahead=$(python3 - "$REPORTS_JSON" <<'PYEOF'
import json, sys
from datetime import datetime, date

with open(sys.argv[1]) as f:
    data = json.load(f)

pending = [
    e["run_at"]
    for r in data.get("reports", [])
    for e in r.get("expanded_schedule", [])
    if e.get("status") == "pending"
]

if not pending:
    print(0)
else:
    latest = datetime.fromisoformat(max(pending)).date()
    print(max((latest - date.today()).days, 0))
PYEOF
    )

    if [[ "$days_ahead" -lt 14 ]]; then
        log "Expanding schedules (${days_ahead} day(s) of pending entries remaining)..."
        python3 "$SCRIPT_DIR/expand_schedules.py" "$REPORTS_JSON"
    fi
}

# ---------------------------------------------------------------------------
# Run one report
# ---------------------------------------------------------------------------
run_report() {
    local id="$1"
    local due_run_at="${2:-}"   # set when triggered by expanded_schedule; empty for --all/--report-id
    local label advertiser_id output_dir drive_folder_id campaign_ids

    label=$(jq_report "$id" ".label")
    advertiser_id=$(jq_report "$id" ".advertiser_id")
    output_dir=$(jq_report "$id" ".output_dir")
    drive_folder_id=$(jq_report "$id" ".drive_folder_id")
    campaign_ids=$(jq_report "$id" '.campaign_ids | join(" ")')

    local date_range_mode
    date_range_mode=$(jq_report "$id" '.schedule.date_range_mode // "static"')

    local start end
    if [[ "$date_range_mode" == "previous_week" ]]; then
        # Always compute Sun–Sat of the week prior to the current Monday
        read -r start end < <(python3 -c "
from datetime import datetime, timedelta
today = datetime.now()
this_monday = today - timedelta(days=today.weekday())
sun = this_monday - timedelta(days=8)
sat = this_monday - timedelta(days=2)
print(sun.strftime('%Y-%m-%d'), sat.strftime('%Y-%m-%d'))
")
    else
        start=$(jq_report "$id" ".schedule.date_range.start")
        end=$(jq_report "$id" ".schedule.date_range.end")
    fi

    local triggered_at
    triggered_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Build filename-safe date range from flight dates e.g. 20260501-20260518
    local start_slug end_slug flight_slug
    start_slug=$(echo "$start" | tr -d '-')
    end_slug=$(echo "$end"   | tr -d '-')
    flight_slug="${start_slug}-${end_slug}"

    # Build human-readable flight label for Drive title e.g. "May 1 - May 18, 2026"
    local flight_label
    flight_label=$(python3 -c "
from datetime import datetime
s = datetime.strptime('$start', '%Y-%m-%d')
e = datetime.strptime('$end',   '%Y-%m-%d')
print(f\"{s.strftime('%b %-d')} - {e.strftime('%b %-d, %Y')}\")
")

    local base="${SCRIPT_DIR}/${output_dir}${id}_${flight_slug}"
    local campaigns_json="${base}_campaigns.json"
    local creatives_json="${base}_creatives.json"
    local pptx_path="${base}.pptx"
    local drive_title="${label} — ${flight_label}"

    log "▶  Report: $label ($id)"

    # Mark expanded_schedule entry as running
    [[ -n "$due_run_at" ]] && mark_schedule_entry "$id" "$due_run_at" "running"

    # Mark run history as running
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

        [[ -n "$due_run_at" ]] && mark_schedule_entry "$id" "$due_run_at" "failed"
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

        [[ -n "$due_run_at" ]] && mark_schedule_entry "$id" "$due_run_at" "failed"
        update_last_run "$id" "$(jq -n \
            --arg t "$triggered_at" --arg e "$err" --arg ed "$detail" \
            --arg cs "$campaigns_json" --arg cr "$creatives_json" \
            '{triggered_at:$t,status:"failed",error_step:"generate",error:$e,error_detail:$ed,campaigns_json:$cs,creatives_json:$cr,pptx_path:null,drive_url:null}')"
        rm -f "$gen_stderr"
        return 1
    fi
    rm -f "$gen_stderr"
    ok "PPTX generated → ${pptx_path##*/}"

    # ── Step 3: Upload ────────────────────────────────────────────────────
    step "Step 3/3 — Uploading..."
    local upload_stderr drive_url
    upload_stderr=$(mktemp)

    if ! drive_url=$("$SCRIPT_DIR/upload_to_google_drive.sh" \
            --file "$pptx_path" \
            --folder-id "$drive_folder_id" \
            --title "$drive_title" \
            2>"$upload_stderr"); then

        local err
        err=$(cat "$upload_stderr")

        fail "STEP FAILED: upload_to_google_drive.sh"
        fail "  Report  : $label"
        fail "  Error   : $err"
        fail "  Note    : PPTX saved locally at $pptx_path"

        [[ -n "$due_run_at" ]] && mark_schedule_entry "$id" "$due_run_at" "failed"
        update_last_run "$id" "$(jq -n \
            --arg t "$triggered_at" --arg e "$err" \
            --arg cs "$campaigns_json" --arg cr "$creatives_json" --arg pp "$pptx_path" \
            '{triggered_at:$t,status:"failed",error_step:"upload",error:$e,error_detail:$e,campaigns_json:$cs,creatives_json:$cr,pptx_path:$pp,drive_url:null}')"
        rm -f "$upload_stderr"
        return 1
    fi

    rm -f "$upload_stderr"
    ok "Uploaded: ${drive_url:-'(URL not captured)'}"

    # ── Success ───────────────────────────────────────────────────────────
    [[ -n "$due_run_at" ]] && mark_schedule_entry "$id" "$due_run_at" "completed"
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

# Auto-expand schedules if running low (skip for manual overrides)
if [[ "$RUN_ALL" == false && -z "$TARGET_ID" ]]; then
    maybe_expand_schedules
fi

TOTAL=0
PASSED=0
FAILED=0

# Iterate over enabled reports
while IFS= read -r id; do
    # Filter by --report-id if specified
    if [[ -n "$TARGET_ID" && "$id" != "$TARGET_ID" ]]; then
        continue
    fi

    # Determine if this report is due
    due_run_at=""
    if [[ "$RUN_ALL" == false && -z "$TARGET_ID" ]]; then
        due_run_at=$(find_due_entry "$id")
        [[ -z "$due_run_at" ]] && continue
    fi

    TOTAL=$((TOTAL + 1))
    if run_report "$id" "${due_run_at}"; then
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
