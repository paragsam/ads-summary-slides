# ads-summary-slides

Automated TikTok Ads performance reports as beautiful slides. Slide format is based on your branded PowerPoint template.

## What it does

A cron-driven pipeline that:

1. Reads a report queue from `reports.json`
2. Fetches campaign and creative metrics from the TikTok Marketing API
3. Generates a branded PPTX slide deck from your template
4. Uploads the finished deck to Google Drive

## Slides generated

- **Performance By Objective** — key metrics (Cost, Impressions, CPM, CTR, CPC, VTR, ER) across campaign objectives
- **Performance By Creative** — top 5 creatives by cost, one slide per campaign objective

## Quick start

### 1. Clone the repo

```bash
git clone https://github.com/paragsam/ads-summary-slides.git
cd ads-summary-slides
```

### 2. Install Python dependencies

Requires **Python 3.9+**.

```bash
pip install -r requirements.txt
```

### 3. Install and authenticate the `gws` CLI

The Google Drive upload step uses the [Google Workspace CLI (`gws`)](https://github.com/googleworkspace/cli). Follow the installation and authentication steps in that repo, then verify it works:

```bash
gws drive files list
```

### 4. Set up TikTok API credentials

Copy `.env.example` to `.env` and fill in your TikTok Marketing API credentials:

```bash
cp .env.example .env
```

Edit `.env`:

```
TIKTOK_APP_ID=your_app_id
TIKTOK_SECRET=your_secret
TIKTOK_ACCESS_TOKEN=your_access_token
```

### 5. Add your branded templates

Templates live in the `templates/` directory and are selected automatically based on the number of campaigns in your report. Three templates are included — replace them with your own branded versions, keeping the same filenames:

```
templates/
├── Brand_Objective_1_campaign.pptx   # Used when report has 1 campaign
├── Brand_Objective_2_campaign.pptx   # Used when report has 2 campaigns
└── Brand_Objective_3_campaign.pptx   # Used when report has 3 campaigns
```

### 6. Configure your reports

Edit `reports.json` to add your reports. The file is self-documented — follow the `_instructions` section at the top.

```bash
nano reports.json
```

Key fields per report:

| Field | Example | Description |
|-------|---------|-------------|
| `id` | `"weekly-brand-report"` | Unique slug, used in filenames |
| `schedule` | `"weekly on monday at 8am"` | Plain English, Pacific Time |
| `advertiser_id` | `"1234567890123456789"` | TikTok advertiser account ID |
| `campaign_ids` | `["111", "222"]` | 1–3 campaign IDs |
| `date_range` | `{"start": "2026-05-01", "end": "2026-05-18"}` | Date range for data pull |
| `drive_folder_id` | `"1AbCdEf..."` | Google Drive folder ID |

### 7. Run manually

```bash
# Run all enabled reports
./run_reports.sh --all

# Run a specific report by ID
./run_reports.sh --report-id weekly-brand-report
```

### 8. Run individual steps (for testing)

```bash
# Step 1 — fetch data from TikTok API
python3 fetch_tiktok_data.py \
  --advertiser-id YOUR_ADVERTISER_ID \
  --campaign-ids YOUR_CAMPAIGN_ID \
  --start 2026-05-10 \
  --end 2026-05-16 \
  --out output/test.json

# Step 2 — generate PPTX from fetched data
python3 generate_pptx.py \
  --campaigns output/test_campaigns.json \
  --creatives output/test_creatives.json \
  --start 2026-05-10 \
  --end 2026-05-16 \
  --out output/test.pptx
```

### 9. Set up cron

```bash
# Open crontab
crontab -e

# Add this line — checks every 15 minutes
*/15 * * * * /path/to/ads-summary-slides/run_reports.sh >> /var/log/ads-summary-slides.log 2>&1
```

## Project structure

```
ads-summary-slides/
├── reports.json              # Report queue and run history
├── run_reports.sh            # Main orchestrator (coming soon)
├── fetch_tiktok_data.py      # Step 1: TikTok API → JSON
├── generate_pptx.py          # Step 2: JSON → PPTX
├── upload_to_google_drive.sh # Step 3: PPTX → Google Drive
├── templates/                # Branded PPTX templates (1–3 campaigns)
├── output/                   # Generated files (gitignored)
├── docs/                     # Design documentation
└── .env                      # Credentials (gitignored, copy from .env.example)
```

## Requirements

- Python 3.9+
- [`gws` CLI](https://github.com/googleworkspace/cli) installed and authenticated with Google Drive access
- TikTok Marketing API access token

## License

MIT — see [LICENSE](LICENSE)
