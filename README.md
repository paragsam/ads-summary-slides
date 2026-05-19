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

### 1. Install dependencies

```bash
pip install -r requirements.txt
```

### 2. Install and authenticate the `gws` CLI

The Google Drive upload step uses the [Google Workspace CLI (`gws`)](https://github.com/googleworkspace/cli). Follow the installation and authentication steps in that repo, then verify it works:

```bash
gws drive files list
```

### 3. Set up credentials

Copy `.env.example` to `.env` and fill in your TikTok API credentials:

```bash
cp .env.example .env
```

```
TIKTOK_APP_ID=your_app_id
TIKTOK_SECRET=your_secret
TIKTOK_ACCESS_TOKEN=your_access_token
```

### 4. Add your template

Place your branded PowerPoint template in the `templates/` directory.

### 5. Configure reports

Edit `reports.json` to add your reports. The file is self-documented — open it and follow the instructions at the top.

### 6. Run manually

```bash
# Run all enabled reports
./run_reports.sh --all

# Run a specific report by ID
./run_reports.sh --report-id weekly-brand-overview
```

### 7. Set up cron

```bash
# Add to crontab — checks every 15 minutes
*/15 * * * * /path/to/ads-summary-slides/run_reports.sh >> /var/log/ads-summary-slides.log 2>&1
```

## Project structure

```
ads-summary-slides/
├── reports.json              # Report queue and run history
├── run_reports.sh            # Main orchestrator
├── fetch_tiktok_data.py      # Step 1: TikTok API → CSV
├── generate_pptx.py          # Step 2: CSV → PPTX
├── upload_to_drive.sh        # Step 3: PPTX → Google Drive
├── templates/                # Your branded PPTX templates
├── output/                   # Generated files (gitignored)
├── docs/                     # Design documentation
└── .env                      # Credentials (gitignored)
```

## Requirements

- Python 3.10+
- [`gws` CLI](https://github.com/googleworkspace/cli) installed and authenticated with Google Drive access
- TikTok Marketing API access token

## License

MIT — see [LICENSE](LICENSE)
