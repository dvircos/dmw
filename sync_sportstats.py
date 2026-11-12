"""Low-volume SportStatsAPI fixture importer.

This adapter deliberately imports upcoming fixtures only. It never requests
per-match detail endpoints, changes Winner odds, or settles results.
"""
from __future__ import annotations

import argparse
import logging
import os
import re
from datetime import datetime, timedelta, timezone, time
from zoneinfo import ZoneInfo
from typing import Any

import requests
from team_utils import FLAGS, flag_url, hebrew_name, normalize

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



# Hebrew display names and verified Football-Data crest IDs for the current
# Premier League / La Liga clubs. National teams continue to use their flags.
CLUBS = {
    "ath bilbao": ("אתלטיק בילבאו", 77),
    "athletic bilbao": ("אתלטיק בילבאו", 77),
    "espanyol": ("אספניול", 80),
    "manchester city": ("מנצ'סטר סיטי", 65),
    "fulham": ("פולהאם", 63),
    "alaves": ("אלאבס", 263),
    "deportivo la coruna": ("דפורטיבו לה קורוניה", 560),
    "dep a coruna": ("דפורטיבו לה קורוניה", 560),
    "tottenham": ("טוטנהאם", 73),
    "tottenham hotspur": ("טוטנהאם", 73),
    "ipswich": ("איפסוויץ'", 349),
    "chelsea": ("צ'לסי", 61),
    "leeds": ("לידס יונייטד", 341),
    "coventry": ("קובנטרי", 1076),
    "crystal palace": ("קריסטל פאלאס", 354),
    "aston villa": ("אסטון וילה", 58),
    "sunderland": ("סנדרלנד", 71),
    "bournemouth": ("בורנמות'", 1044),
    "nottingham": ("נוטינגהאם פורסט", 351),
    "nottingham forest": ("נוטינגהאם פורסט", 351),
    "rayo vallecano": ("ראיו וייקאנו", 87),
    "valencia": ("ולנסיה", 95),
    "newcastle": ("ניוקאסל", 67),
    "newcastle united": ("ניוקאסל", 67),
    "arsenal": ("ארסנל", 57),
    "sevilla": ("סביליה", 559),
    "betis": ("בטיס", 90),
    "real betis": ("בטיס", 90),
    "real madrid": ("ריאל מדריד", 86),
    "celta vigo": ("סלטה ויגו", 558),
    "barcelona": ("ברצלונה", 81),
    "villarreal": ("ויאריאל", 94),
    "hull": ("האל סיטי", 64),
    "brighton": ("ברייטון", 397),
    "racing santander": ("ראסינג סנטנדר", 745),
    "real sociedad": ("ריאל סוסיאדד", 92),
    "liverpool": ("ליברפול", 64),
    "manchester utd": ("מנצ'סטר יונייטד", 66),
    "manchester united": ("מנצ'סטר יונייטד", 66),
    "osasuna": ("אוסאסונה", 79),
    "malaga": ("מלאגה", 98),
    "getafe": ("חטאפה", 82),
    "atl. madrid": ("אתלטיקו מדריד", 78),
    "atletico madrid": ("אתלטיקו מדריד", 78),
    "brentford": ("ברנטפורד", 402),
    "everton": ("אברטון", 62),
    "levante": ("לבאנטה", 88),
    "elche": ("אלצ'ה", 285),
    "nottingham forest": ("נוטינגהאם פורסט", 351),
    "leicester": ("לסטר סיטי", 338),
    "west ham": ("ווסטהאם", 563),
    "wolves": ("וולבס", 76),
    "wolverhampton": ("וולבס", 76),
}

UCL_LOGOS = {
"aek athens": 887, "as roma": 104, "roma": 104, "bodo/glimt": 2980, "bodø/glimt": 2980,
"lask": 4411, "lask linz": 4411, "galatasaray": 432, "dortmund": 124, "borussia dortmund": 124,
"slovan bratislava": 521, "rb leipzig": 11420, "lens": 175, "feyenoord": 142, "fc porto": 437,
"porto": 437, "como": 2572, "como 1907": 2572, "sabah baku": 21922, "sabah fk": 21922,
"slavia prague": 494, "slavia praha": 494, "viking": 510, "viking fk": 510, "shakhtar donetsk": 493,
"fenerbahce": 436, "fenerbahçe": 436, "psg": 160, "paris saint-germain": 160, "lille": 166,
"bayern munich": 132, "inter": 110, "stuttgart": 134, "vfb stuttgart": 134,
"club brugge kv": 570, "club brugge": 570, "sporting cp": 2250, "napoli": 114, "psv": 148, "psv eindhoven": 148
}

def team_display(name: str) -> str:
    entry = CLUBS.get(normalize(name))
    return entry[0] if entry else hebrew_name(name)

def team_logo_url(team: dict[str, Any], name: str) -> str | None:
    # Prefer a provider-supplied image URL when present in the list payload.
    for key in ("logo", "image", "badge", "crest", "logo_url", "image_url"):
        value = team.get(key)
        if isinstance(value, str) and value.startswith("https://"):
            return value
    key = normalize(name)
    if key in UCL_LOGOS:
        return f"https://a.espncdn.com/i/teamlogos/soccer/500/{UCL_LOGOS[key]}.png"
    entry = CLUBS.get(key)
    return f"https://crests.football-data.org/{entry[1]}.png" if entry else safe_team_flag(name)


def safe_team_flag(name: str) -> str | None:
    """Do not replace a real existing club badge with the generic unknown flag."""
    if normalize(name) not in FLAGS:
        return None
    return flag_url(name, None)


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

    def rpc(self, name: str | dict[str, Any], payload: dict[str, Any] | None = None) -> Any:
        # Preserve the concise fixture-upsert call while supporting quota and result RPCs.
        if payload is None:
            rpc_name = "upsert_sportstats_fixture"
            rpc_payload = name
        else:
            rpc_name = str(name)
            rpc_payload = payload
        response = requests.post(
            f"{self.supabase_url}/rest/v1/rpc/{rpc_name}",
            headers=self.db_headers, json=rpc_payload, timeout=35,
        )
        if response.status_code >= 300:
            raise RuntimeError(f"Supabase RPC {rpc_name} failed: HTTP {response.status_code}: {response.text[:300]}")
        return response.json() if response.content else None

    def sync_fixtures(self, days: int = 7) -> int:
        now = datetime.now(timezone.utc)
        start, end = now.date().isoformat(), (now + timedelta(days=days)).date().isoformat()
        imported = 0
        for code, label, name in LEAGUES:
            league = {"code": code, "label": label, "name": name}
            # Reserve quota before every SportStatsAPI request, including fixture imports.
            allowed = self.rpc("reserve_api_requests", {"p_count": 1, "p_emergency": False})
            if allowed is not True:
                log.warning("Daily provider quota reached; stopping fixture import before another request.")
                break
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
                    "p_home_team": team_display(home),
                    "p_away_team": team_display(away),
                    "p_home_flag": team_logo_url(raw.get("home_team") or {}, home),
                    "p_away_flag": team_logo_url(raw.get("away_team") or {}, away),
                    "p_match_time": match["kickoff"],
                    "p_round_name": f"{label}|{match['league_name']}",
                })
                imported += 1
                log.info("Fixture %s (%s): %s", match["code"], label, result)
        log.info("Fixture import complete: %s fixtures, %s provider requests", imported, self.api_calls)
        return imported

    def fetch_unconfirmed_games(self, now: datetime) -> list[dict[str, Any]]:
        # Keep checking every unconfirmed fixture from today until it is
        # explicitly confirmed FT. GitHub scheduled runs can be delayed; a
        # hard 3-hour lower bound could permanently drop a match before the
        # provider publishes its final status.
        israel = ZoneInfo("Asia/Jerusalem")
        local_date = now.astimezone(israel).date()
        day_start = datetime.combine(local_date, time.min, tzinfo=israel).astimezone(timezone.utc)
        day_end = datetime.combine(local_date + timedelta(days=1), time.min, tzinfo=israel).astimezone(timezone.utc)
        active_window_end = min(day_end, now - timedelta(minutes=30))
        if active_window_end <= day_start:
            return []
        params = {
            "select": "id,sportstats_match_code,sportstats_league_code,match_time",
            "sportstats_match_code": "not.is.null",
            "sportstats_league_code": "not.is.null",
            "result_confirmed": "eq.false",
            "match_time": f"gt.{day_start.isoformat()}",
            "and": f"(match_time.lte.{active_window_end.isoformat()})",
            "status": "in.(upcoming,live)",
            "order": "match_time.asc",
            "limit": "500",
        }
        response = requests.get(
            f"{self.supabase_url}/rest/v1/games",
            headers=self.db_headers, params=params, timeout=35,
        )
        if response.status_code >= 300:
            raise RuntimeError(f"Could not load pending SportStatsAPI games: HTTP {response.status_code}: {response.text[:300]}")
        rows = response.json()
        if not isinstance(rows, list):
            raise RuntimeError("Unexpected Supabase games response")
        return rows

    @staticmethod
    def live_score(row: dict[str, Any]) -> tuple[int, int, int | None, str] | None:
        """Return a score only when the provider explicitly marks the match in play."""
        status = str(row.get("status") or "").strip().upper()
        status_code = str(row.get("status_code") or "").strip().lower()
        if status == "HT":
            minute = None
        elif re.fullmatch(r"\d{1,3}(?:\+\d{1,2})?", status):
            raw_minute = row.get("minute")
            minute = raw_minute if isinstance(raw_minute, int) and 0 <= raw_minute <= 200 else int(status.split("+", 1)[0])
        elif status in {"LIVE", "1H", "2H", "ET", "BT", "P"} and status_code in {"live", "in_progress", "halftime"}:
            raw_minute = row.get("minute")
            minute = raw_minute if isinstance(raw_minute, int) and 0 <= raw_minute <= 200 else None
        else:
            return None
        home = row.get("home_team") or {}
        away = row.get("away_team") or {}
        hs, aws = home.get("score"), away.get("score")
        if not (isinstance(hs, int) and isinstance(aws, int) and hs >= 0 and aws >= 0):
            return None
        return hs, aws, minute, status

    @staticmethod
    def final_score(row: dict[str, Any]) -> tuple[int, int] | None:
        # Only FT is accepted: AET/PEN are intentionally excluded because
        # settlement must use the regular-time score, not extra time/shootouts.
        # SportStatsAPI documents soccer finality with status="FT".
        # status_code is a cross-sport normalization field; do not require
        # its value to be the literal "final" for a canonical soccer FT row.
        if str(row.get("status") or "").strip().upper() != "FT":
            return None
        home = row.get("home_team") or {}
        away = row.get("away_team") or {}
        hs, aws = home.get("score"), away.get("score")
        if isinstance(hs, int) and isinstance(aws, int) and hs >= 0 and aws >= 0:
            return hs, aws
        # Fallback only to the provider's explicit full-time score string.
        score = str(row.get("full_time_score") or "")
        match = re.fullmatch(r"\s*\[\s*(\d+)\s*[-:]\s*(\d+)\s*\]\s*", score)
        if match:
            return int(match.group(1)), int(match.group(2))
        return None

    def sync_results(self) -> int:
        now = datetime.now(timezone.utc)
        games = self.fetch_unconfirmed_games(now)
        if not games:
            log.info("No unconfirmed SportStatsAPI-linked games from today are in one of the five post-kickoff polling windows; 0 provider requests.")
            return 0

        league_codes = sorted({str(g["sportstats_league_code"]) for g in games if g.get("sportstats_league_code")})
        league_lookup = {code: (label, name) for code, label, name in LEAGUES}
        known_codes = [code for code in league_codes if code in league_lookup]
        if not known_codes:
            log.info("No supported SportStatsAPI leagues among pending games; 0 provider requests.")
            return 0

        israel_today = now.astimezone(ZoneInfo("Asia/Jerusalem")).date().isoformat()
        start = end = israel_today
        by_code = {str(g["sportstats_match_code"]): g for g in games}
        confirmed = 0

        for league_code in known_codes:
            # Reserve quota before the provider request; never retry or paginate.
            allowed = self.rpc("reserve_api_requests", {"p_count": 1, "p_emergency": False})
            if allowed is not True:
                log.warning("Daily provider quota reached; stopping before another SportStatsAPI request.")
                break
            rows = self.fetch_league(league_code, start, end)
            for row in rows:
                match_code = str(row.get("code") or "").strip()
                if match_code not in by_code:
                    continue
                score = self.final_score(row)
                if score is not None:
                    result = self.rpc("sync_sportstats_result", {
                        "p_match_code": match_code,
                        "p_home_score": score[0],
                        "p_away_score": score[1],
                    })
                    confirmed += 1
                    log.info("Confirmed SportStatsAPI final result %s: %s-%s; settlement RPC=%s",
                             match_code, score[0], score[1], result)
                    continue

                live = self.live_score(row)
                if live is None:
                    continue
                result = self.rpc("sync_sportstats_live_score", {
                    "p_match_code": match_code,
                    "p_home_score": live[0],
                    "p_away_score": live[1],
                    "p_live_minute": live[2],
                    "p_live_status_text": live[3],
                })
                log.info("Updated live SportStatsAPI score %s: %s-%s (%s); no settlement; RPC=%s",
                         match_code, live[0], live[1], live[3], result)

        log.info("Results sync complete: %s results confirmed, %s provider requests.", confirmed, self.api_calls)
        return confirmed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("fixtures", "results"))
    parser.add_argument("--days", type=int, default=7)
    args = parser.parse_args()
    if not 1 <= args.days <= 31:
        parser.error("--days must be between 1 and 31")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    sync = SportStatsSync()
    if args.mode == "fixtures":
        if os.environ.get("GITHUB_EVENT_NAME") == "schedule":
            local_now = datetime.now(timezone.utc).astimezone(ZoneInfo("Asia/Jerusalem"))
            if local_now.hour != 6:
                log.info("Outside the scheduled Israel 06:00 fixture import; no provider calls.")
                return
        sync.sync_fixtures(args.days)
    else:
        sync.sync_results()


if __name__ == "__main__":
    main()
