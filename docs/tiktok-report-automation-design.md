# TikTok Ads Report Automation — Design Document

## Overview

A cron-driven pipeline that reads a report queue, fetches TikTok Ads data, generates PPTX slide decks from a template, and uploads them to Google Drive.

```
cron (every 15 min)
 └─ run_reports.sh
      ├─ reads   reports.json        (queue + status)
      ├─ calls   fetch_tiktok_data.py  → CSV
      ├─ calls   generate_pptx.py      → PPTX
      ├─ calls   upload_to_drive.sh    → Google Drive
      └─ writes  status + error back to reports.json
```

---

## 1. Report Queue File (`reports.json`)

### Design Goals

- Human-readable and hand-editable
- Machine-writable by OpenClaw or any LLM agent on the same machine
- Tracks both configuration (what to run) and status (what happened)
- Single source of truth — no separate state file
- Errors and short status written here so OpenClaw can scan for failures

### Schema

```json
{
  "version": "1",
  "reports": [
    {
      "id": "weekly-brand-overview",
      "label": "Weekly Brand Overview",
      "schedule": "0 8 * * 1",
      "advertiser_id": "7123456789012345678",
      "campaign_ids": ["111111111", "222222222", "333333333"],
      "date_range": {
        "start": "2026-05-01",
        "end": "2026-05-18"
      },
      "template": "templates/Performance_By_Objective_template.pptx",
      "output_dir": "output/",
      "drive_folder_id": "1AbCdEfGhIjKlMnOpQrStUvWx",
      "enabled": true,
      "runs": [
        {
          "triggered_at": "2026-05-19T08:00:00Z",
          "status": "success",
          "csv_path": "output/weekly-brand-overview_20260519.csv",
          "pptx_path": "output/weekly-brand-overview_20260519.pptx",
          "drive_url": "https://drive.google.com/file/d/...",
          "error": null,
          "error_step": null,
          "error_detail": null
        }
      ]
    }
  ]
}
```

### Field Reference

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique slug; used in output filenames and logs |
| `label` | string | Human display name |
| `schedule` | string | Cron expression controlling when this report runs |
| `advertiser_id` | string | TikTok Ads advertiser account ID |
| `campaign_ids` | string[] | Campaign IDs to include; empty array = all under the advertiser |
| `date_range.start` | ISO date | Inclusive start date (`YYYY-MM-DD`) |
| `date_range.end` | ISO date | Inclusive end date (`YYYY-MM-DD`) |
| `template` | path | PPTX template path relative to project root |
| `output_dir` | path | Directory for CSV and PPTX output files |
| `drive_folder_id` | string | Google Drive folder ID to upload into |
| `enabled` | bool | Set to `false` to skip without deleting the entry |
| `runs[]` | array | Append-only history of executions |
| `runs[].status` | enum | `"success"` \| `"failed"` \| `"running"` |
| `runs[].error` | string\|null | One-line error summary (null on success) |
| `runs[].error_step` | string\|null | Which step failed: `"fetch"` \| `"generate"` \| `"upload"` |
| `runs[].error_detail` | string\|null | Full error message or stack trace excerpt |

### Notes for OpenClaw / LLM Agents

- To **add** a report: append an object to `reports[]`
- To **disable** a report: set `"enabled": false`
- To **reschedule**: update the `schedule` field (cron syntax)
- To **check for failures**: scan `runs[]` entries where `status == "failed"` and read `error` + `error_detail`
- Never delete entries from `runs[]` — always append

---

## 2. TikTok Data Fetcher (`fetch_tiktok_data.py`)

### Responsibilities

- Authenticate using a long-lived app-level access token from environment variables
- Accept advertiser ID, campaign ID list, and date range as CLI arguments
- Fetch per-campaign metrics **and** campaign details (name, objective type) from the TikTok Marketing API
- Fetch per-creative metrics scoped to each campaign
- Write a structured CSV to a specified output path
- Print a one-line JSON error to stderr and exit non-zero on failure

### Interface

```bash
python fetch_tiktok_data.py \
  --advertiser-id 7123456789 \
  --campaign-ids 111 222 333 \
  --start 2026-05-01 \
  --end 2026-05-18 \
  --out output/weekly-brand-overview_20260519.csv
```

### Output CSV — Campaign-level rows

```
date, campaign_id, campaign_name, objective_type,
impressions, clicks, ctr, spend, cpm, cpc,
reach, vtr, vtr_6s, engagement_rate, conversions, roas
```

`objective_type` is the raw TikTok API value (e.g. `REACH`, `VIDEO_VIEWS`, `TRAFFIC`) and is used downstream to group columns in the PPTX.

### Output CSV — Creative-level rows (appended or separate file)

```
campaign_id, campaign_name, objective_type,
creative_id, creative_name,
impressions, clicks, ctr, spend, cpm, cpc, vtr, vtr_6s, engagement_rate
```

The fetcher writes two CSVs: `<stem>_campaigns.csv` and `<stem>_creatives.csv`.

### Credentials (env vars, loaded from `.env`)

```
TIKTOK_APP_ID
TIKTOK_SECRET
TIKTOK_ACCESS_TOKEN
```

---

## 3. PPTX Generator (`generate_pptx.py`)

### Responsibilities

- Read the two CSVs produced by the fetcher
- Load `Performance_By_Objective_template.pptx`
- Generate the output deck:
  - **Slide 1** — Performance By Objective (one column per campaign objective)
  - **Slides 2–4** — Performance By Creative, one slide per campaign objective (cloned from template Slide 2), showing top 5 creatives by cost
- Replace date label (`MM/DD–MM/DD`) auto-formatted from `--start` / `--end`
- Write the completed PPTX to the output path

### Interface

```bash
python generate_pptx.py \
  --campaigns output/weekly-brand-overview_20260519_campaigns.csv \
  --creatives output/weekly-brand-overview_20260519_creatives.csv \
  --template templates/Performance_By_Objective_template.pptx \
  --start 2026-05-01 \
  --end 2026-05-18 \
  --out output/weekly-brand-overview_20260519.pptx
```

### Slide Structure

#### Slide 1 — Performance By Objective

Reuses template Slide 1 as-is. The 4-column table has one metric column per campaign objective, ordered by how they appear in the data.

| Row | Metric |
|-----|--------|
| 0 | Header: Metrics \| Objective A \| Objective B \| Objective C |
| 1 | Cost |
| 2 | Impressions |
| 3 | CPM |
| 4 | Reach |
| 5 | Clicks (destination) |
| 6 | CTR (destination) |
| 7 | CPC (Destination) |
| 8 | VTR |
| 9 | 6-Sec VTR |
| 10 | Engagement Rate |

The column headers are replaced with the `objective_type` values from the data (e.g. `REACH → "Reach"`).

#### Slides 2–4 — Performance By Creative (one per objective)

Template Slide 2 is cloned once per campaign objective. Each clone:

- Title updated to `"Performance By Creative — <Objective Name>"`
- Date label replaced with `MM/DD–MM/DD`
- Table filled with top 5 creatives by cost for that objective
- If fewer than 5 creatives exist, remaining rows are left blank
- Rows are added dynamically (up to 5) by copying the last data row's XML to preserve formatting

Table columns match the template: `Creative | Cost | Impressions | CPM | CTR | CPC | 6s VTR | VTR | ER`

### Implementation Notes

- Reuses `SlideGenerator` and `fill_table` from the existing `slide-generator` project at `/Users/bytedance/Projects/slide-generator/`
- Slide cloning uses `python-pptx` XML copy (`copy.deepcopy` on `slide._element`)
- Row insertion copies the last row's `<a:tr>` element to preserve cell formatting

---

## 4. Google Drive Uploader (`upload_to_drive.sh`)

### Responsibilities

- Upload a local PPTX to a specified Google Drive folder using the `gws` CLI
- Print the resulting Drive URL to stdout
- Exit non-zero on failure with a clear error message

### Interface

```bash
./upload_to_drive.sh \
  --file output/weekly-brand-overview_20260519.pptx \
  --folder-id 1AbCdEfGhIjKlMnOpQrStUvWx \
  --title "Weekly Brand Overview — May 1–18 2026"
```

### Implementation

```bash
gws drive files create \
  --upload "$FILE" \
  --name "$TITLE" \
  --parent "$FOLDER_ID"
```

No Python wrapper needed — `run_reports.sh` calls `gws` directly. Install and authenticate `gws` by following the steps at [github.com/googleworkspace/cli](https://github.com/googleworkspace/cli). Once authenticated, the CLI handles all credentials.

---

## 5. Orchestration Script (`run_reports.sh`)

### Responsibilities

- Parse `reports.json` and identify which enabled reports are due (schedule matches current time)
- Support manual override flags to run all reports or a specific report by ID
- Run each report's pipeline steps in sequence: fetch → generate → upload
- After each step failure: write `status="failed"`, `error`, `error_step`, `error_detail` to `reports.json` and continue to next report
- On full success: write `status="success"`, `csv_path`, `pptx_path`, `drive_url`
- Produce timestamped, readable terminal output at each step

### Flow

```
for each report where enabled=true and schedule matches now:
  1. Write status="running" to reports.json
  2. fetch_tiktok_data.py
       on failure → write status="failed", error_step="fetch", continue
  3. generate_pptx.py
       on failure → write status="failed", error_step="generate", continue
  4. upload_to_drive.sh
       on failure → write status="failed", error_step="upload", continue
       (PPTX is still saved locally even if upload fails)
  5. Write status="success", paths, drive_url to reports.json
```

### Error Output Format

```
[2026-05-19 08:03:12] ✗ STEP FAILED: fetch_tiktok_data.py
  Report  : weekly-brand-overview
  Command : python fetch_tiktok_data.py --advertiser-id 7123 ...
  Exit    : 1
  Error   : {"code": "auth_expired", "message": "Access token has expired"}
  Action  : Skipping generate and upload steps for this report.
```

### Manual Override Flags

```bash
# Run all enabled reports regardless of schedule
./run_reports.sh --all

# Run a single report by ID
./run_reports.sh --report-id weekly-brand-overview
```

### Cron Entry

```cron
# Fires every 15 min; script filters by each report's schedule internally
*/15 * * * * /path/to/project/run_reports.sh >> /var/log/tiktok-reports.log 2>&1
```

---

## 6. Directory Layout

```
project/
├── reports.json                               # Queue + run history (edit to add reports)
├── .env                                       # Credentials (never committed)
├── run_reports.sh                             # Main orchestrator
├── fetch_tiktok_data.py                       # Step 1: TikTok API → CSV
├── generate_pptx.py                           # Step 2: CSV → PPTX
├── upload_to_drive.sh                         # Step 3: PPTX → Google Drive
├── templates/
│   └── Performance_By_Objective_template.pptx
├── output/                                    # Generated CSVs and PPTXs
│   ├── weekly-brand-overview_20260519_campaigns.csv
│   ├── weekly-brand-overview_20260519_creatives.csv
│   └── weekly-brand-overview_20260519.pptx
└── logs/                                      # Symlink target for cron log
```

---

## 7. Credentials Summary

| Secret | Where stored | Used by |
|--------|-------------|---------|
| `TIKTOK_APP_ID` | `.env` | `fetch_tiktok_data.py` |
| `TIKTOK_SECRET` | `.env` | `fetch_tiktok_data.py` |
| `TIKTOK_ACCESS_TOKEN` | `.env` | `fetch_tiktok_data.py` |
| Google Drive auth | `gws` CLI auth config (set up once via `gws login`) | `run_reports.sh` via `gws drive files create` |

---

## 8. Decisions Log

| # | Question | Decision |
|---|----------|----------|
| 1 | TikTok auth | Long-lived app-level access token stored in `.env` |
| 2 | Date range format | Explicit static `YYYY-MM-DD` dates only |
| 3 | PPTX template | `Performance_By_Objective_template.pptx` (existing) |
| 4 | Failure alerting | Write `error` + `error_detail` to `reports.json`; OpenClaw scans for failures |
| 5 | Drive upload tool | `gws drive files create --upload` |
| 6 | Campaign columns | Grouped by `objective_type` pulled from TikTok API |
| 7 | Creative scoping | Per campaign objective |
| 8 | Creative slide layout | One slide per campaign objective, cloned from template Slide 2 |
| 9 | Creatives per slide | Top 5 by cost; rows added dynamically up to 5 |
| 10 | Date label | Auto-formatted `MM/DD–MM/DD` from `date_range.start` / `date_range.end` |
