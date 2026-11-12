"""Low-volume SportStatsAPI fixture importer.

This adapter deliberately imports upcoming fixtures only. It never requests
per-match detail endpoints, changes Winner odds, or settles results.
"""
from __future__ import annotations

import argparse
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import requests
from main import flag_url, hebrew_name

API_BASE = "https://api.sportstatsapi.com/api/v1"
# Confirmed from the completed league-catalogue diagnostic; do not rescan catalogue.
LEAGUES = (
    ("l30", "england", "Premier League"),
    ("l6t", "spain", "La Liga"),
    ("l46", "israel", "Ligat Ha'Al"),
    ("lml", "nations", "UEFA Nations League"),
    ("l3", "ucl", "UEFA Champions League"),
)
SCHEDULED = {"NS", "TBD"}
PLACEHOLDERS = {"", "YOUR_SPORTSTATS_API_KEY_HERE"}
log = logging.getLogger("sportstats-sync")


def parse_match(row: dict[str, Any], league: dict[str, str]) -> dict[str, Any] | None:
    """Validate and normalize one SportStatsAPI list-row; no detail lookup."""
    code = str(row.get("code") or "").strip()
    home = row.get("home_team") or {}
    away = row.get("away_team") or {}
    start = row.get("start_at") or row.get("start_date")
    status = str(row.get("status") or "").upper()
    if not code or not start or status not in SCHEDULED:
        return None
    home_name = str(home.get("display_name") or home.get("name") or "").strip()
    away_name = str(away.get("display_name") or away.get("name") or "").strip()
    if not home_name or not away_name:
        return None
    try:
        kickoff = datetime.fromisoformat(str(start).replace("Z", "+00:00"))
        if kickoff.tzinfo is None:
            return None
        home_code = str(home.get("code") or "").strip()
        away_code = str(away.get("code") or "").strip()
        if not home_code or not away_code:
            return None
    except (TypeError, ValueError):
        return None
    return {
        "code": code,
        "league_code": league["code"],
        "league_name": str(row.get("league_name") or league["name"]),
        "home_name": home_name,
        "away_name": away_name,
        "home_code": home_code,
        "away_code": away_code,
        "kickoff": kickoff.astimezone(timezone.utc).isoformat(),
    }


class SportStatsSync:
    def __init__(self) -> None:
        self.api_key = os.environ.get("SPORTSTATS_API_KEY", "").strip()
        self.supabase_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
        self.service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
        if self.api_key in PLACEHOLDERS or not self.supabase_url or not self.service_key:
            raise RuntimeError("SPORTSTATS_API_KEY, SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {self.api_key}", "Accept": "application/json"})
        self.db_headers = {
            "apikey": self.service_key,
            "Authorization": f"Bearer {self.service_key}",
            "Content-Type": "application/json",
        }
        self.api_calls = 0

    def fetch_league(self, league_code: str, start: str, end: str) -> list[dict[str, Any]]:
        # Exactly one list request per league. No retries and no detail endpoint calls.
        response = self.session.get(
            f"{API_BASE}/soccer/matches",
            params={"league_id": league_code, "date_from": start, "date_to": end,
                    "limit": 100, "order": "asc"},
            timeout=35,
        )
        self.api_calls += 1
        if response.status_code in (401, 403):
            raise RuntimeError(f"SportStatsAPI rejected the configured key (HTTP {response.status_code})")
        if response.status_code == 429:
            raise RuntimeError("SportStatsAPI rate limit reached; stopped without retry")
        response.raise_for_status()
        body = response.json()
        if body.get("success") is not True or not isinstance(body.get("data"), list):
            raise RuntimeError(f"Unexpected SportStatsAPI response for league {league_code}")
        total = int((body.get("meta") or {}).get("total") or len(body["data"]))
        if total > len(body["data"]):
            log.warning("League %s has %s rows but only %s were requested; omitted overflow safely",
                        league_code, total, len(body["data"]))
        return body["data"]

    def rpc(self, payload: dict[str, Any]) -> Any:
        response = requests.post(
            f"{self.supabase_url}/rest/v1/rpc/upsert_sportstats_fixture",
            headers=self.db_headers, json=payload, timeout=35,
        )
        if response.status_code >= 300:
            raise RuntimeError(f"Supabase upsert_sportstats_fixture failed: HTTP {response.status_code}: {response.text[:300]}")
        return response.json() if response.content else None

    def sync_fixtures(self, days: int = 14) -> int:
        now = datetime.now(timezone.utc)
        start, end = now.date().isoformat(), (now + timedelta(days=days)).date().isoformat()
        imported = 0
        for code, label, name in LEAGUES:
            league = {"code": code, "label": label, "name": name}
            rows = self.fetch_league(code, start, end)
            for raw in rows:
                match = parse_match(raw, league)
                if not match:
                    continue
                home, away = match["home_name"], match["away_name"]
                result = self.rpc({
                    "p_match_code": match["code"],
                    "p_league_code": match["league_code"],
                    "p_league_name": match["league_name"],
                    "p_home_team_code": match["home_code"],
                    "p_away_team_code": match["away_code"],
                    "p_api_home_name": home,
                    "p_api_away_name": away,
                    "p_home_team": hebrew_name(home),
                    "p_away_team": hebrew_name(away),
                    "p_home_flag": flag_url(home, None),
                    "p_away_flag": flag_url(away, None),
                    "p_match_time": match["kickoff"],
                    "p_round_name": f"sportstats|{match['league_name']}",
                })
                imported += 1
                log.info("Fixture %s (%s): %s", match["code"], label, result)
        log.info("Fixture import complete: %s fixtures, %s provider requests", imported, self.api_calls)
        return imported


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("fixtures",))
    parser.add_argument("--days", type=int, default=14)
    args = parser.parse_args()
    if not 1 <= args.days <= 31:
        parser.error("--days must be between 1 and 31")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    SportStatsSync().sync_fixtures(args.days)


if __name__ == "__main__":
    main()
