"""Sync UEFA Nations League fixtures and settle 90-minute results.

Bets are graded only from regular-time fulltime goals. Extra time and
penalties never change the stored score or a ticket's outcome.
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import requests

log = logging.getLogger("nations-sync")

API_BASE = "https://v3.football.api-sports.io"
LEAGUE_ID = 5
BET365_ID = 8
PLACEHOLDERS = {"", "YOUR_SPORTS_API_KEY_HERE"}
REGULAR_TIME_DONE = {"FT", "AET", "PEN", "ET", "BT", "P"}
LIVE = {"1H", "HT", "2H", "LIVE", "INT", "SUSP"}
CANCELLED = {"CANC", "ABD", "AWD", "WO"}

NAMES = {
    "albania": "אלבניה",
    "andorra": "אנדורה",
    "armenia": "ארמניה",
    "austria": "אוסטריה",
    "azerbaijan": "אזרבייג'ן",
    "belarus": "בלארוס",
    "belgium": "בלגיה",
    "bosnia and herzegovina": "בוסניה והרצגובינה",
    "bulgaria": "בולגריה",
    "croatia": "קרואטיה",
    "cyprus": "קפריסין",
    "czech republic": "צ'כיה",
    "czechia": "צ'כיה",
    "denmark": "דנמרק",
    "england": "אנגליה",
    "estonia": "אסטוניה",
    "faroe islands": "איי פארו",
    "finland": "פינלנד",
    "france": "צרפת",
    "georgia": "גאורגיה",
    "germany": "גרמניה",
    "gibraltar": "גיברלטר",
    "greece": "יוון",
    "hungary": "הונגריה",
    "iceland": "איסלנד",
    "israel": "ישראל",
    "italy": "איטליה",
    "kazakhstan": "קזחסטן",
    "kosovo": "קוסובו",
    "latvia": "לטביה",
    "liechtenstein": "ליכטנשטיין",
    "lithuania": "ליטא",
    "luxembourg": "לוקסמבורג",
    "malta": "מלטה",
    "moldova": "מולדובה",
    "montenegro": "מונטנגרו",
    "netherlands": "הולנד",
    "holland": "הולנד",
    "north macedonia": "מקדוניה הצפונית",
    "macedonia": "מקדוניה הצפונית",
    "northern ireland": "צפון אירלנד",
    "norway": "נורווגיה",
    "poland": "פולין",
    "portugal": "פורטוגל",
    "republic of ireland": "אירלנד",
    "ireland": "אירלנד",
    "romania": "רומניה",
    "russia": "רוסיה",
    "san marino": "סן מרינו",
    "scotland": "סקוטלנד",
    "serbia": "סרביה",
    "slovakia": "סלובקיה",
    "slovenia": "סלובניה",
    "spain": "ספרד",
    "sweden": "שבדיה",
    "switzerland": "שווייץ",
    "turkey": "טורקיה",
    "turkiye": "טורקיה",
    "ukraine": "אוקראינה",
    "wales": "ויילס",
}

FLAGS = {
    "albania": "al",
    "andorra": "ad",
    "armenia": "am",
    "austria": "at",
    "azerbaijan": "az",
    "belarus": "by",
    "belgium": "be",
    "bosnia and herzegovina": "ba",
    "bulgaria": "bg",
    "croatia": "hr",
    "cyprus": "cy",
    "czech republic": "cz",
    "czechia": "cz",
    "denmark": "dk",
    "england": "gb-eng",
    "estonia": "ee",
    "faroe islands": "fo",
    "finland": "fi",
    "france": "fr",
    "georgia": "ge",
    "germany": "de",
    "gibraltar": "gi",
    "greece": "gr",
    "hungary": "hu",
    "iceland": "is",
    "israel": "il",
    "italy": "it",
    "kazakhstan": "kz",
    "kosovo": "xk",
    "latvia": "lv",
    "liechtenstein": "li",
    "lithuania": "lt",
    "luxembourg": "lu",
    "malta": "mt",
    "moldova": "md",
    "montenegro": "me",
    "netherlands": "nl",
    "holland": "nl",
    "north macedonia": "mk",
    "macedonia": "mk",
    "northern ireland": "gb-nir",
    "norway": "no",
    "poland": "pl",
    "portugal": "pt",
    "republic of ireland": "ie",
    "ireland": "ie",
    "romania": "ro",
    "russia": "ru",
    "san marino": "sm",
    "scotland": "gb-sct",
    "serbia": "rs",
    "slovakia": "sk",
    "slovenia": "si",
    "spain": "es",
    "sweden": "se",
    "switzerland": "ch",
    "turkey": "tr",
    "turkiye": "tr",
    "ukraine": "ua",
    "wales": "gb-wls",
}


def normalize(name: str) -> str:
    text = (name or "").strip().lower().replace("&", " and ").replace(".", "")
    text = text.replace("ü", "u").replace("'", "")
    return " ".join(text.split())


def hebrew_name(name: str) -> str:
    return NAMES.get(normalize(name), name)


def flag_url(name: str, logo: str | None) -> str:
    code = FLAGS.get(normalize(name))
    if code:
        return f"https://flagcdn.com/w80/{code}.png"
    if logo and logo.startswith("https://"):
        return logo
    return "https://flagcdn.com/w80/un.png"


def clamp_odd(value) -> str | None:
    if value in (None, ""):
        return None
    try:
        number = round(float(value), 2)
    except (TypeError, ValueError):
        return None
    if number < 1.01 or number > 99.99:
        return None
    return f"{number:.2f}"


class FootballClient:
    def __init__(self, api_key: str):
        self.session = requests.Session()
        self.session.headers.update({"x-apisports-key": api_key})

    def get(self, path: str, params: dict) -> dict | None:
        response = self.session.get(f"{API_BASE}{path}", params=params, timeout=40)
        if response.status_code in (401, 403):
            log.warning("Sports API rejected the key (HTTP %s). Existing games were left as they are.", response.status_code)
            return None
        if response.status_code == 429:
            log.warning("Sports API rate limit reached. Stopping this run.")
            return None
        response.raise_for_status()
        payload = response.json()
        errors = payload.get("errors")
        if errors:
            log.warning("Sports API returned an error payload: %s", errors)
            if errors not in ({}, []):
                return None
        return payload

    def get_pages(self, path: str, params: dict, limit: int = 6) -> list[dict] | None:
        rows: list[dict] = []
        page = 1
        while page <= limit:
            body = self.get(path, {**params, "page": page})
            if body is None:
                return None if page == 1 else rows
            rows.extend(body.get("response") or [])
            total = ((body.get("paging") or {}).get("total")) or 1
            if page >= total:
                break
            page += 1
        return rows


def choose_season(client: FootballClient, today) -> tuple[int, list[dict]] | None:
    start = (today - timedelta(days=3)).isoformat()
    end = (today + timedelta(days=21)).isoformat()
    for season in (today.year, today.year - 1, today.year - 2):
        fixtures = client.get_pages("/fixtures", {"league": LEAGUE_ID, "season": season, "from": start, "to": end})
        if fixtures is None:
            return None
        if fixtures:
            log.info("Using Nations League season %s (%s fixtures in window).", season, len(fixtures))
            return season, fixtures
    log.info("No Nations League fixtures in the current window.")
    return None


def extract_1x2(bookmakers: list[dict]) -> dict[str, str | None] | None:
    fallback = None
    for bookmaker in bookmakers or []:
        parsed = None
        for bet in bookmaker.get("bets") or []:
            name = (bet.get("name") or "").lower()
            if name not in {"match winner", "1x2", "match result"}:
                continue
            odds = {"1": None, "X": None, "2": None}
            for value in bet.get("values") or []:
                label = (value.get("value") or "").lower()
                odd = clamp_odd(value.get("odd"))
                if label in {"home", "1"}:
                    odds["1"] = odd
                elif label in {"draw", "x"}:
                    odds["X"] = odd
                elif label in {"away", "2"}:
                    odds["2"] = odd
            if all(odds.values()):
                parsed = odds
                break
        if not parsed:
            continue
        if bookmaker.get("id") == BET365_ID or (bookmaker.get("name") or "").lower() == "bet365":
            return parsed
        fallback = fallback or parsed
    return fallback


def map_status(short: str, score: dict, goals: dict) -> tuple[str, int, int] | None:
    fulltime = score.get("fulltime") or {}
    if short in REGULAR_TIME_DONE:
        if fulltime.get("home") is None or fulltime.get("away") is None:
            log.warning("Regular time marked complete (%s) but fulltime score is missing. Skipping.", short)
            return None
        return "finished", int(fulltime["home"]), int(fulltime["away"])
    if short in LIVE:
        return "live", int(goals.get("home") or 0), int(goals.get("away") or 0)
    if short in CANCELLED:
        return "cancelled", int(fulltime.get("home") or 0), int(fulltime.get("away") or 0)
    return "upcoming", 0, 0


def build_payload(fixture: dict, odds: dict[str, str | None] | None) -> dict | None:
    info = fixture.get("fixture") or {}
    teams = fixture.get("teams") or {}
    home = teams.get("home") or {}
    away = teams.get("away") or {}
    if not info.get("id") or not info.get("date") or not home.get("name") or not away.get("name"):
        return None
    mapped = map_status((info.get("status") or {}).get("short") or "NS", fixture.get("score") or {}, fixture.get("goals") or {})
    if mapped is None:
        return None
    status, home_score, away_score = mapped
    odds = odds or {}
    return {
        "p_fixture_id": info["id"],
        "p_home_team": hebrew_name(home["name"]),
        "p_away_team": hebrew_name(away["name"]),
        "p_home_flag": flag_url(home["name"], home.get("logo")),
        "p_away_flag": flag_url(away["name"], away.get("logo")),
        "p_match_time": info["date"],
        "p_home_odds": odds.get("1"),
        "p_draw_odds": odds.get("X"),
        "p_away_odds": odds.get("2"),
        "p_home_score": home_score,
        "p_away_score": away_score,
        "p_status": status,
    }


def push(url: str, service_key: str, payload: dict) -> None:
    response = requests.post(
        f"{url.rstrip('/')}/rest/v1/rpc/sync_game_result",
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=40,
    )
    if response.status_code >= 300:
        log.error("Sync failed for fixture %s: HTTP %s %s", payload["p_fixture_id"], response.status_code, response.text[:300])
        response.raise_for_status()
    log.info(
        "Fixture %s %s vs %s -> %s %s-%s",
        payload["p_fixture_id"],
        payload["p_home_team"],
        payload["p_away_team"],
        payload["p_status"],
        payload["p_home_score"],
        payload["p_away_score"],
    )


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    url = os.environ.get("SUPABASE_URL", "").strip()
    service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "").strip()
    api_key = os.environ.get("API_KEY", "").strip()
    if not url or not service_key:
        log.error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required.")
        return 1
    if api_key in PLACEHOLDERS:
        log.warning("API_KEY is not set. Demo fixtures stay in place until a real sports key is added.")
        return 0

    client = FootballClient(api_key)
    today = datetime.now(timezone.utc).date()
    chosen = choose_season(client, today)
    if not chosen:
        return 0
    season, fixtures = chosen
    odds_rows = client.get_pages("/odds", {"league": LEAGUE_ID, "season": season, "bookmaker": BET365_ID})
    if odds_rows is None:
        odds_rows = []
    odds_by_fixture: dict[int, dict[str, str | None]] = {}
    for row in odds_rows:
        fixture_id = (row.get("fixture") or {}).get("id")
        parsed = extract_1x2(row.get("bookmakers") or [])
        if fixture_id and parsed:
            odds_by_fixture[fixture_id] = parsed
    if not odds_by_fixture:
        log.info("Bet365 1X2 prices were not in this response. Fixtures will sync without replacing odds.")

    failures = 0
    for fixture in fixtures:
        payload = build_payload(fixture, odds_by_fixture.get((fixture.get("fixture") or {}).get("id")))
        if not payload:
            continue
        try:
            push(url, service_key, payload)
        except requests.RequestException:
            failures += 1
    if failures:
        log.error("%s fixture updates failed.", failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
