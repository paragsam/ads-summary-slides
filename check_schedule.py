"""
Check whether a plain-English schedule should run now (Pacific Time).

Exit 0 if the schedule matches the current time window, exit 1 if not.

Usage:
  python3 check_schedule.py "weekly on monday at 8am"

Supported formats:
  hourly
  daily at 9am
  weekly on monday at 8am
  monthly on the 1st at 9am

The cron fires every 15 minutes. A schedule matches if the current time
falls within the first 15 minutes of the scheduled hour.
"""

from __future__ import annotations

import re
import sys
from datetime import datetime

try:
    from zoneinfo import ZoneInfo
    PT = ZoneInfo("America/Los_Angeles")
except ImportError:
    from datetime import timezone, timedelta  # type: ignore
    PT = timezone(timedelta(hours=-7))  # rough fallback (no DST)

DAYS: dict[str, int] = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

WINDOW = 15  # minutes — matches the cron interval


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


def in_window(now_hour: int, now_min: int, target_hour: int) -> bool:
    return now_hour == target_hour and 0 <= now_min < WINDOW


def should_run(schedule: str, now: datetime) -> bool:
    s = schedule.strip().lower()
    h, mn, dow, dom = now.hour, now.minute, now.weekday(), now.day

    if s == "hourly":
        return 0 <= mn < WINDOW

    if s.startswith("daily at "):
        return in_window(h, mn, parse_hour(s[len("daily at "):]))

    if s.startswith("weekly on "):
        rest = s[len("weekly on "):]
        parts = re.split(r"\s+at\s+", rest, maxsplit=1)
        if len(parts) != 2:
            return False
        return dow == DAYS.get(parts[0].strip(), -1) and in_window(h, mn, parse_hour(parts[1]))

    if s.startswith("monthly on the "):
        rest = s[len("monthly on the "):]
        parts = re.split(r"\s+at\s+", rest, maxsplit=1)
        if len(parts) != 2:
            return False
        target_dom = int(re.sub(r"\D", "", parts[0]) or "1")
        return dom == target_dom and in_window(h, mn, parse_hour(parts[1]))

    return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: check_schedule.py <schedule>", file=sys.stderr)
        sys.exit(2)

    try:
        now = datetime.now(PT)
    except Exception:
        now = datetime.utcnow()

    sys.exit(0 if should_run(sys.argv[1], now) else 1)
