#!/usr/bin/env python3
"""
expand_schedules.py — Pre-compute run dates for each enabled report.

Reads reports.json, generates concrete run datetimes for the next N months
based on each report's schedule.frequency, and writes them back into the
expanded_schedule field.  Existing entries are preserved (their status is
never overwritten); only new pending entries are added.

Usage:
  python3 expand_schedules.py [path/to/reports.json] [--months N]

Defaults:
  path  — reports.json in the same directory as this script
  months — 2
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

DAYS: dict[str, int] = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

RUN_AT_FMT = "%Y-%m-%dT%H:%M"


def parse_hour(s: str) -> int:
    s = s.strip().lower()
    m = re.match(r"(\d+)(?::\d+)?\s*(am|pm)?", s)
    if not m:
        return 0
    hour, meridiem = int(m.group(1)), m.group(2)
    if meridiem == "pm" and hour != 12:
        hour += 12
    elif meridiem == "am" and hour == 12:
        hour = 0
    return hour


def generate_run_datetimes(frequency: str, start: date, end: date) -> list[datetime]:
    """Return sorted list of naive datetimes (Pacific Time) for each scheduled run."""
    f = frequency.strip().lower()
    results: list[datetime] = []
    current = start

    if f.startswith("weekly on "):
        rest = f[len("weekly on "):]
        parts = re.split(r"\s+at\s+", rest, maxsplit=1)
        if len(parts) != 2:
            return []
        target_dow = DAYS.get(parts[0].strip(), -1)
        hour = parse_hour(parts[1])
        while current <= end:
            if current.weekday() == target_dow:
                results.append(datetime(current.year, current.month, current.day, hour, 0))
            current += timedelta(days=1)

    elif f.startswith("daily at "):
        hour = parse_hour(f[len("daily at "):])
        while current <= end:
            results.append(datetime(current.year, current.month, current.day, hour, 0))
            current += timedelta(days=1)

    elif f.startswith("monthly on the "):
        rest = f[len("monthly on the "):]
        parts = re.split(r"\s+at\s+", rest, maxsplit=1)
        if len(parts) != 2:
            return []
        dom = int(re.sub(r"\D", "", parts[0]) or "1")
        hour = parse_hour(parts[1])
        seen: set[tuple] = set()
        while current <= end:
            key = (current.year, current.month)
            if key not in seen:
                seen.add(key)
                try:
                    d = date(current.year, current.month, dom)
                    if start <= d <= end:
                        results.append(datetime(d.year, d.month, d.day, hour, 0))
                except ValueError:
                    pass
            current += timedelta(days=1)

    elif f == "hourly":
        dt = datetime(current.year, current.month, current.day, 0, 0)
        end_dt = datetime(end.year, end.month, end.day, 23, 0)
        while dt <= end_dt:
            results.append(dt)
            dt += timedelta(hours=1)

    return sorted(results)


def expand(reports_json: Path, months: int = 2) -> None:
    data = json.loads(reports_json.read_text())
    today = date.today()
    end_date = today + timedelta(days=months * 30)

    for report in data.get("reports", []):
        if not report.get("enabled"):
            continue

        schedule = report.get("schedule", {})
        frequency = schedule.get("frequency", "") if isinstance(schedule, dict) else ""
        if not frequency:
            print(f"  Skipping {report.get('id')} — no schedule.frequency set",
                  file=sys.stderr)
            continue

        run_dts = generate_run_datetimes(frequency, today, end_date)

        # Preserve existing entries (never overwrite a non-pending status)
        existing: dict[str, dict] = {
            e["run_at"]: e
            for e in report.get("expanded_schedule", [])
        }

        new_schedule: list[dict] = []
        for dt in run_dts:
            run_at = dt.strftime(RUN_AT_FMT)
            new_schedule.append(existing.get(run_at, {"run_at": run_at, "status": "pending"}))

        report["expanded_schedule"] = new_schedule
        print(f"  {report['id']}: {len(new_schedule)} entries "
              f"({today} → {end_date})")

    reports_json.write_text(json.dumps(data, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "reports_json", nargs="?",
        default=Path(__file__).parent / "reports.json",
        type=Path,
    )
    parser.add_argument("--months", type=int, default=2,
                        help="How many months ahead to generate (default: 2)")
    args = parser.parse_args()

    if not args.reports_json.exists():
        print(f"Error: {args.reports_json} not found", file=sys.stderr)
        sys.exit(1)

    print(f"Expanding schedules → {args.reports_json}")
    expand(args.reports_json, args.months)
    print("Done.")
