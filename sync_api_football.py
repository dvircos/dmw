"""Separated API-Football jobs: weekly fixture catalogue and evening results polling."""
from __future__ import annotations

import argparse
import logging
import os
from datetime import date, datetime, timedelta, timezone
from urllib.parse import quote
from zoneinfo import ZoneInfo

import requests
from main import flag_url, hebrew_name

API_BASE = "https://v3.football.api-sports.io"
ISRAEL_TZ = ZoneInfo("Asia/Jerusalem")
# Verified API-Football competition IDs: Israel Ligat Ha'al 202, UCL 2,
# La Liga 140, Premier League 39, UEFA Nations League 633.
LEAGUES = ((202, "israel"), (2, "ucl"), (140, "spain"), (39, "england"), (633, "nations"))
LIVE_STATUSES = {"1H", "HT", "2H", "ET", "BT", "P", "LIVE", "INT", "SUSP"}
FINAL_STATUSES = {"FT", "AET", "PEN"}
CANCELLED_STATUSES = {"CANC"}
PLACEHOLDERS = {"", "YOUR_SPORTS_API_KEY_HERE"}
log = logging.getLogger("api-football-sync")


def chunks(values: list[int], size: int = 20):
    for start in range(0, len(values), size):
        yield values[start:start + size]


def parse_api_result(item: dict) -> tuple[str, int | None, int | None] | None:
    """Only terminal FT/AET/PEN are final; ET and shootout-in-progress stay live."""
    fixture = item.get("fixture") or {}
    short = str((fixture.get("status") or {}).get("short") or "").upper()
    score = item.get("score") or {}
    if short in FINAL_STATUSES:
        regular = score.get("fulltime") or {}
        home, away = regular.get("home"), regular.get("away")
        if home is None or away is None:
            return None
        return "finished", int(home), int(away)
    if short in CANCELLED_STATUSES:
        return "cancelled", 0, 0
    if short in LIVE_STATUSES:
        goals = item.get("goals") or {}
        home, away = goals.get("home"), goals.get("away")
        return "live", None if home is None else int(home), None if away is None else int(away)
    return None


class Sync:
    def __init__(self):
        self.url = os.environ["SUPABASE_URL"].rstrip("/")
        key = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
        api_key = os.environ["API_KEY"]
        if not self.url or not key or api_key in PLACEHOLDERS:
            raise RuntimeError("SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and API_FOOTBALL API_KEY are required")
        self.db_headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
        self.session = requests.Session()
        self.session.headers.update({"x-apisports-key": api_key})
        self.calls = 0

    def reserve(self):
        r = requests.post(f"{self.url}/rest/v1/rpc/reserve_api_requests",
            headers=self.db_headers, json={"p_count": 1, "p_emergency": False}, timeout=30)
        r.raise_for_status()
        if r.json() is not True:
            raise RuntimeError("Local daily API safety budget (80 requests) reached; stopping safely")

    def api_get(self, params: dict, purpose: str) -> list[dict]:
        self.reserve()
        r = self.session.get(f"{API_BASE}/fixtures", params=params, timeout=40)
        self.calls += 1
        if r.status_code in (401, 403):
            raise RuntimeError(f"API-Football rejected API_KEY (HTTP {r.status_code})")
        if r.status_code == 429:
            raise RuntimeError("API-Football daily or per-minute limit reached; no retry attempted")
        r.raise_for_status()
        body = r.json()
        if body.get("errors") not in (None, {}, []):
            raise RuntimeError(f"API-Football error for {purpose}: {body['errors']}")
        rows = body.get("response") or []
        total = int((body.get("paging") or {}).get("total") or 1)
        page = int(params.get("page", 1))
        if total > page:
            for next_page in range(page + 1, total + 1):
                rows.extend(self.api_get({**params, "page": next_page}, purpose))
        return rows

    def rpc(self, name: str, payload: dict):
        r = requests.post(f"{self.url}/rest/v1/rpc/{name}", headers=self.db_headers, json=payload, timeout=40)
        if r.status_code >= 300:
            raise RuntimeError(f"Supabase {name} failed: HTTP {r.status_code}: {r.text[:300]}")
        return r.json() if r.content else None

    def get_active_games(self, now: datetime) -> list[dict]:
        # Only games already in the app whose kickoff has passed, not yet settled,
        # and mapped to an API-Football fixture ID. Future fixtures are never polled here.
        lower = (now - timedelta(days=2)).isoformat()
        upper = now.isoformat()
        params = {
            "select": "id,api_football_fixture_id,status,match_time",
            "api_football_fixture_id": "not.is.null",
            "status": "in.(upcoming,live)",
            "result_confirmed": "eq.false",
            "and": f"(match_time.gte.{lower},match_time.lte.{upper})",
            "order": "match_time.asc",
            "limit": "500",
        }
        r = requests.get(f"{self.url}/rest/v1/games", headers=self.db_headers, params=params, timeout=40)
        r.raise_for_status()
        return r.json()

    @staticmethod
    def team_label(team: dict) -> str:
        return str(team.get("name") or "").strip()

    def sync_fixtures(self):
        now = datetime.now(timezone.utc)
        start = now.date()
        end = (now + timedelta(days=7)).date()
        inserted_or_updated = 0
        for league_id, code in LEAGUES:
            season = now.year if now.month >= 7 else now.year - 1
            rows = self.api_get({
                "league": league_id, "season": season,
                "from": start.isoformat(), "to": end.isoformat(),
                "timezone": "Asia/Jerusalem",
            }, f"weekly-fixtures-{code}")
            for item in rows:
                fixture = item.get("fixture") or {}
                status = str((fixture.get("status") or {}).get("short") or "").upper()
                # The weekly catalogue job only creates/updates not-yet-started fixtures.
                if status not in {"NS", "TBD", "PST"}:
                    continue
                teams = item.get("teams") or {}
                home, away = teams.get("home") or {}, teams.get("away") or {}
                if not fixture.get("id") or not fixture.get("date") or not home.get("name") or not away.get("name"):
                    continue
                league = item.get("league") or {}
                result = self.rpc("link_api_football_fixture", {
                    "p_api_fixture_id": int(fixture["id"]),
                    "p_league_code": code,
                    "p_api_home_name": self.team_label(home),
                    "p_api_away_name": self.team_label(away),
                    "p_match_time": fixture["date"],
                })
                if result and result.get("linked"):
                    inserted_or_updated += 1
                log.info("Existing game fixture link: %s (%s)", fixture["id"], result)
        log.info("Weekly catalogue complete: %s fixtures; %s API requests", inserted_or_updated, self.calls)

    def sync_results(self):
        now = datetime.now(timezone.utc)
        games = self.get_active_games(now)
        ids = sorted({int(g["api_football_fixture_id"]) for g in games if g.get("api_football_fixture_id")})
        if not ids:
            log.info("No started or imminent unsettled app games; 0 API requests used")
            return
        by_id = {int(g["api_football_fixture_id"]): g for g in games}
        for batch in chunks(ids, 20):
            rows = self.api_get({"ids": "-".join(map(str, batch)), "timezone": "Asia/Jerusalem"}, "active-app-results")
            returned = set()
            for item in rows:
                fixture = item.get("fixture") or {}
                api_id = int(fixture.get("id") or 0)
                if api_id not in by_id:
                    continue
                returned.add(api_id)
                parsed = parse_api_result(item)
                if not parsed:
                    continue
                status, home_score, away_score = parsed
                game = by_id[api_id]
                kickoff = datetime.fromisoformat(game["match_time"].replace("Z", "+00:00"))
                if status == "finished":
                    short = str((fixture.get("status") or {}).get("short") or "").upper()
                    minimum = 120 if short in {"AET", "PEN"} else 95
                    if now < kickoff + timedelta(minutes=minimum):
                        log.info("Final status received but safety delay not elapsed for %s", api_id)
                        continue
                    result = self.rpc("sync_api_football_result", {
                        "p_api_fixture_id": api_id, "p_status": "finished",
                        "p_home_score": home_score, "p_away_score": away_score,
                    })
                    log.info("Final result applied: %s -> %s", api_id, result)
                elif status == "cancelled":
                    result = self.rpc("sync_api_football_result", {
                        "p_api_fixture_id": api_id, "p_status": "cancelled",
                        "p_home_score": 0, "p_away_score": 0,
                    })
                    log.info("Cancelled fixture refunded: %s -> %s", api_id, result)
                else:
                    self.rpc("sync_api_football_live", {
                        "p_api_fixture_id": api_id,
                        "p_home_score": home_score,
                        "p_away_score": away_score,
                    })
                    log.info("Live score refreshed: %s", api_id)
            missing = set(batch) - returned
            if missing:
                log.warning("API-Football returned no fixture rows for mapped IDs: %s", sorted(missing))
        log.info("Results polling complete: %s app games checked in %s API requests", len(ids), self.calls)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("fixtures", "results"))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    job = Sync()
    if args.mode == "fixtures":
        job.sync_fixtures()
    else:
        job.sync_results()


if __name__ == "__main__":
    main()
