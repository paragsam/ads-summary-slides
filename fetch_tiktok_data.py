"""
Fetch TikTok Ads campaign and creative metrics and write to JSON + CSV.

Outputs four files derived from --out:
  <stem>_campaigns.json  — one object per campaign, totals for the date range
  <stem>_campaigns.csv   — same data in CSV format
  <stem>_creatives.json  — one object per ad/creative, totals for the date range
  <stem>_creatives.csv   — same data in CSV format

Usage:
  python fetch_tiktok_data.py \
    --advertiser-id 7123456789 \
    --campaign-ids 111 222 333 \
    --start 2026-05-01 \
    --end 2026-05-18 \
    --out output/report.json

Credentials are read from environment variables (or a .env file):
  TIKTOK_APP_ID, TIKTOK_SECRET, TIKTOK_ACCESS_TOKEN
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()

BASE_URL = "https://business-api.tiktok.com/open_api/v1.3"
PAGE_SIZE = 100


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

def die(message: str, detail: str = "") -> None:
    payload: dict = {"error": message}
    if detail:
        payload["detail"] = detail
    print(json.dumps(payload), file=sys.stderr)
    sys.exit(1)


def safe_div(numerator: float, denominator: float, scale: float = 100.0) -> str:
    if not denominator:
        return "0.00%"
    return f"{(numerator / denominator) * scale:.2f}%"


def headers() -> dict:
    token = os.getenv("TIKTOK_ACCESS_TOKEN")
    if not token:
        die("Missing TIKTOK_ACCESS_TOKEN environment variable")
    return {"Access-Token": token, "Content-Type": "application/json"}


# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

def encode_params(payload: dict) -> dict:
    """JSON-encode any list or dict values so they can be sent as GET query params."""
    return {
        k: json.dumps(v) if isinstance(v, (list, dict)) else v
        for k, v in payload.items()
    }


def get_all_pages(url: str, hdrs: dict, payload: dict) -> list[dict]:
    """Paginate through all pages of a TikTok API GET response and return all list items."""
    items = []
    page = 1
    while True:
        paged = encode_params({**payload, "page": page, "page_size": PAGE_SIZE})
        resp = requests.get(url, headers=hdrs, params=paged, timeout=30)
        resp.raise_for_status()
        body = resp.json()

        if body.get("code") != 0:
            die(f"TikTok API error: {body.get('message', 'unknown')}", json.dumps(body))

        data = body["data"]
        items.extend(data.get("list") or [])

        page_info = data.get("page_info", {})
        if page >= page_info.get("total_page", 1):
            break
        page += 1

    return items


# ---------------------------------------------------------------------------
# Data fetching
# ---------------------------------------------------------------------------

def fetch_campaign_info(advertiser_id: str, campaign_ids: list[str], hdrs: dict) -> dict[str, dict]:
    """Return {campaign_id: {campaign_name, objective_type}} for all requested campaigns."""
    filtering: dict = {}
    if campaign_ids:
        filtering["campaign_ids"] = campaign_ids

    payload: dict = {"advertiser_id": advertiser_id}
    if filtering:
        payload["filtering"] = json.dumps(filtering)

    items = get_all_pages(f"{BASE_URL}/campaign/get/", hdrs, payload)
    return {
        str(c["campaign_id"]): {
            "campaign_name": c["campaign_name"],
            "objective_type": c["objective_type"],
        }
        for c in items
    }


def fetch_campaign_metrics(
    advertiser_id: str,
    campaign_ids: list[str],
    start: str,
    end: str,
    hdrs: dict,
    extra_metrics: list[str] | None = None,
) -> list[dict]:
    """Fetch aggregated campaign-level metrics for the date range."""
    metrics = [
        "spend", "impressions", "reach", "clicks", "ctr", "cpm", "cpc",
        "video_play_actions", "video_watched_6s", "engagement_rate",
        "conversion", "total_landing_page_view",
    ]
    if extra_metrics:
        metrics += extra_metrics

    payload: dict = {
        "advertiser_id": advertiser_id,
        "report_type": "BASIC",
        "data_level": "AUCTION_CAMPAIGN",
        "dimensions": ["campaign_id"],
        "metrics": metrics,
        "start_date": start,
        "end_date": end,
    }

    if campaign_ids:
        payload["filtering"] = [
            {"field_name": "campaign_ids", "filter_type": "IN", "filter_value": json.dumps(campaign_ids)}
        ]

    return get_all_pages(f"{BASE_URL}/report/integrated/get/", hdrs, payload)


def fetch_ad_metrics(
    advertiser_id: str,
    campaign_ids: list[str],
    start: str,
    end: str,
    hdrs: dict,
    extra_metrics: list[str] | None = None,
) -> list[dict]:
    """Fetch aggregated ad-level (creative) metrics for the date range."""
    metrics = [
        "spend", "impressions", "clicks", "ctr", "cpm", "cpc",
        "video_play_actions", "video_watched_6s", "engagement_rate",
    ]
    if extra_metrics:
        metrics += extra_metrics

    payload: dict = {
        "advertiser_id": advertiser_id,
        "report_type": "BASIC",
        "data_level": "AUCTION_AD",
        "dimensions": ["ad_id"],
        "metrics": metrics,
        "start_date": start,
        "end_date": end,
    }

    if campaign_ids:
        payload["filtering"] = [
            {"field_name": "campaign_ids", "filter_type": "IN", "filter_value": json.dumps(campaign_ids)}
        ]

    return get_all_pages(f"{BASE_URL}/report/integrated/get/", hdrs, payload)


def fetch_ad_details(advertiser_id: str, ad_ids: list[str], hdrs: dict) -> dict[str, dict]:
    """Return {ad_id: {ad_name, campaign_id}} for a list of ad IDs."""
    if not ad_ids:
        return {}

    details: dict[str, dict] = {}
    for i in range(0, len(ad_ids), 100):
        chunk = ad_ids[i : i + 100]
        payload = {
            "advertiser_id": advertiser_id,
            "filtering": json.dumps({"ad_ids": chunk}),
            "fields": json.dumps(["ad_id", "ad_name", "campaign_id"]),
        }
        items = get_all_pages(f"{BASE_URL}/ad/get/", hdrs, payload)
        for ad in items:
            details[str(ad["ad_id"])] = {
                "ad_name": ad.get("ad_name", ""),
                "campaign_id": str(ad.get("campaign_id", "")),
            }

    return details


# ---------------------------------------------------------------------------
# JSON writing
# ---------------------------------------------------------------------------

def build_campaign_record(item: dict, campaign_info: dict[str, dict]) -> dict:
    cid = str(item["dimensions"]["campaign_id"])
    m = item["metrics"]
    impressions = float(m.get("impressions") or 0)
    record = {
        "campaign_id": cid,
        "campaign_name": campaign_info.get(cid, {}).get("campaign_name", ""),
        "objective_type": campaign_info.get(cid, {}).get("objective_type", ""),
        "spend": m.get("spend", "0"),
        "impressions": m.get("impressions", "0"),
        "cpm": m.get("cpm", "0"),
        "reach": m.get("reach", "0"),
        "clicks": m.get("clicks", "0"),
        "ctr": m.get("ctr", "0"),
        "cpc": m.get("cpc", "0"),
        "vtr": safe_div(float(m.get("video_play_actions") or 0), impressions),
        "vtr_6s": safe_div(float(m.get("video_watched_6s") or 0), impressions),
        "engagement_rate": m.get("engagement_rate", "0"),
        "conversions": m.get("conversion", "0"),
        "landing_page_views": m.get("total_landing_page_view", "0"),
    }
    # Brand2Shop fields (present only when fetched with brand2shop template type)
    for field in BRAND2SHOP_CAMPAIGN_METRICS:
        if field in m:
            record[field] = m[field]
    return record


def build_creative_record(item: dict, campaign_info: dict[str, dict], ad_details: dict[str, dict]) -> dict:
    aid = str(item["dimensions"]["ad_id"])
    detail = ad_details.get(aid, {})
    cid = detail.get("campaign_id", "")
    m = item["metrics"]
    impressions = float(m.get("impressions") or 0)
    record = {
        "campaign_id": cid,
        "campaign_name": campaign_info.get(cid, {}).get("campaign_name", ""),
        "objective_type": campaign_info.get(cid, {}).get("objective_type", ""),
        "ad_id": aid,
        "ad_name": detail.get("ad_name", aid),
        "spend": m.get("spend", "0"),
        "impressions": m.get("impressions", "0"),
        "cpm": m.get("cpm", "0"),
        "clicks": m.get("clicks", "0"),
        "ctr": m.get("ctr", "0"),
        "cpc": m.get("cpc", "0"),
        "vtr": safe_div(float(m.get("video_play_actions") or 0), impressions),
        "vtr_6s": safe_div(float(m.get("video_watched_6s") or 0), impressions),
        "engagement_rate": m.get("engagement_rate", "0"),
    }
    for field in BRAND2SHOP_AD_METRICS:
        if field in m:
            record[field] = m[field]
    return record


def write_json(path: Path, data: list[dict], label: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(data, f, indent=2)
    print(f"Wrote {label} JSON: {path}")


def write_csv(path: Path, data: list[dict], label: str) -> None:
    """Write a list of flat dicts to CSV. Column order follows the first record's key order."""
    if not data:
        print(f"No {label} data to write CSV.")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    # Union of all keys (preserving insertion order) so brand2shop extra fields are included
    fieldnames = list(dict.fromkeys(k for record in data for k in record))
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(data)
    print(f"Wrote {label} CSV:  {path}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

BRAND2SHOP_CAMPAIGN_METRICS = [
    # Confirmed valid against TikTok Business API v1.3
    "complete_payment",             # Assisted Purchases
    "complete_payment_rate",        # Purchase rate
    "complete_payment_roas",        # Assisted ROAS
    "total_active_pay_roas",        # Total active pay ROAS
    "on_web_order",                 # Web orders
    # TODO: map these once correct API field names are confirmed:
    # "product_page_view_rate"      → Product Page View Rate (PDP VR)
    # "new_shop_visitor"            → New Shop Visitors (90-day inactive)
    # "assisted_new_shop_visitor"   → Assisted New Shop Visitors (90-day inactive)
    # "cost_per_product_page_view"  → Assisted Cost Per Product Page View
    # "assisted_complete_payment_value" → Assisted Gross Revenue
]

BRAND2SHOP_AD_METRICS = [
    # Confirmed valid against TikTok Business API v1.3
    "complete_payment",
    "complete_payment_rate",
    "complete_payment_roas",
    "on_web_order",
]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch TikTok Ads metrics and write campaign + creative JSON files."
    )
    parser.add_argument("--advertiser-id", required=True, help="TikTok advertiser account ID")
    parser.add_argument("--campaign-ids", nargs="*", default=[], metavar="ID",
                        help="Campaign IDs to include (omit for all campaigns)")
    parser.add_argument("--start", required=True, help="Start date YYYY-MM-DD")
    parser.add_argument("--end", required=True, help="End date YYYY-MM-DD")
    parser.add_argument("--out", required=True, help="Base output path (e.g. output/report.json)")
    parser.add_argument("--template-type", default="brand_objective",
                        choices=["brand_objective", "brand2shop"],
                        help="Report template type (default: brand_objective)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    hdrs = headers()

    base = Path(args.out)
    campaigns_path = base.with_name(base.stem + "_campaigns.json")
    creatives_path = base.with_name(base.stem + "_creatives.json")
    campaigns_csv_path = base.with_name(base.stem + "_campaigns.csv")
    creatives_csv_path = base.with_name(base.stem + "_creatives.csv")

    is_brand2shop = args.template_type == "brand2shop"

    print(f"Fetching campaign info for advertiser {args.advertiser_id}...")
    campaign_info = fetch_campaign_info(args.advertiser_id, args.campaign_ids, hdrs)
    if not campaign_info:
        die("No campaigns found for the given advertiser ID and campaign filters")
    print(f"  Found {len(campaign_info)} campaign(s)")

    print("Fetching campaign metrics...")
    campaign_metric_rows = fetch_campaign_metrics(
        args.advertiser_id, args.campaign_ids, args.start, args.end, hdrs,
        extra_metrics=BRAND2SHOP_CAMPAIGN_METRICS if is_brand2shop else None,
    )
    print(f"  Got {len(campaign_metric_rows)} row(s)")

    print("Fetching creative (ad) metrics...")
    ad_rows = fetch_ad_metrics(
        args.advertiser_id, args.campaign_ids, args.start, args.end, hdrs,
        extra_metrics=BRAND2SHOP_AD_METRICS if is_brand2shop else None,
    )
    print(f"  Got {len(ad_rows)} ad row(s)")

    ad_ids = list({str(r["dimensions"]["ad_id"]) for r in ad_rows})
    print(f"Fetching details for {len(ad_ids)} ad(s)...")
    ad_details = fetch_ad_details(args.advertiser_id, ad_ids, hdrs)

    campaigns = [build_campaign_record(r, campaign_info) for r in campaign_metric_rows]
    creatives = [build_creative_record(r, campaign_info, ad_details) for r in ad_rows]

    write_json(campaigns_path, campaigns, "campaigns")
    write_csv(campaigns_csv_path, campaigns, "campaigns")
    write_json(creatives_path, creatives, "creatives")
    write_csv(creatives_csv_path, creatives, "creatives")


if __name__ == "__main__":
    main()
