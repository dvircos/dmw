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
RAPIDAPI_HOST = "api-football-v1.p.rapidapi.com"
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


class Database:
    def __init__(self, url: str, service_key: str):
        self.url = url.rstrip("/")
        self.headers = {
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        }

    def rpc(self, name: str, payload: dict):
        response = requests.post(f"{self.url}/rest/v1/rpc/{name}", headers=self.headers, json=payload, timeout=40)
        if response.status_code >= 300:
            raise RuntimeError(f"{name} failed: HTTP {response.status_code} {response.text[:240]}")
        if not response.content or not response.text.strip():
            return None
        return response.json()

    def games(self) -> list[dict]:
        response = requests.get(
            f"{self.url}/rest/v1/games",
            headers=self.headers,
            params={
                "select": "fixture_id,home_team,away_team,home_flag,away_flag,match_time,status,round_name,odds_locked,result_confirmed",
                "fixture_id": "lt.900000",
                "order": "match_time.asc",
                "limit": "500",
            },
            timeout=40,
        )
        if response.status_code >= 300:
            raise RuntimeError(f"games read failed: HTTP {response.status_code} {response.text[:240]}")
        return response.json()


def sports_connection(api_key: str) -> tuple[str, dict[str, str]]:
    if "msh" in api_key and "jsn" in api_key:
        return f"https://{RAPIDAPI_HOST}/v3", {
            "x-rapidapi-key": api_key,
            "x-rapidapi-host": RAPIDAPI_HOST,
        }
    return API_BASE, {"x-apisports-key": api_key}


class FootballClient:
    def __init__(self, api_key: str, db: Database):
        self.db = db
        self.stopped = False
        self.last_error = None
        self.base, headers = sports_connection(api_key)
        self.session = requests.Session()
        self.session.headers.update(headers)

    def get(self, path: str, params: dict, purpose: str) -> dict | None:
        if self.stopped:
            return None
        self.last_error = None
        allowed = self.db.rpc("reserve_api_requests", {"p_count": 1, "p_emergency": False})
        if allowed is not True:
            log.warning("Daily operating limit of 80 sports requests was reached. This run stops before the reserved 20.")
            self.stopped = True
            return None
        status = None
        try:
            response = self.session.get(f"{self.base}{path}", params=params, timeout=40)
            status = response.status_code
            if response.status_code in (401, 403):
                self.last_error = {"key": response.text[:180]}
                log.warning("Sports API rejected the key (HTTP %s). Existing games were left as they are.", response.status_code)
                self.stopped = True
                return None
            if response.status_code == 429:
                log.warning("Sports API rate limit reached. Stopping this run.")
                self.stopped = True
                return None
            response.raise_for_status()
            payload = response.json()
            errors = payload.get("errors")
            if errors not in (None, {}, []):
                self.last_error = errors
                log.warning("Sports API returned an error payload: %s", errors)
                return None
            return payload
        finally:
            try:
                self.db.rpc("log_api_request", {
                    "p_endpoint": path,
                    "p_params": params,
                    "p_status": status,
                    "p_purpose": purpose,
                })
            except RuntimeError:
                log.warning("The sports response was received, but the request log could not be written.")

    def get_pages(self, path: str, params: dict, purpose: str, limit: int = 4) -> list[dict] | None:
        rows: list[dict] = []
        page = 1
        while page <= limit:
            body = self.get(path, {**params, "page": page}, purpose)
            if body is None:
                return None
            rows.extend(body.get("response") or [])
            total = ((body.get("paging") or {}).get("total")) or 1
            if page >= total:
                break
            page += 1
        return rows


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


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def build_payload(fixture: dict, odds: dict[str, str | None] | None, *, lock_odds: bool = False, confirm: bool = False) -> dict | None:
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
    league = fixture.get("league") or {}
    if confirm:
        if status not in {"finished", "cancelled"}:
            return None
        sent_odds: dict[str, str | None] = {}
        lock = False
    else:
        lock = bool(lock_odds and odds and all(odds.get(key) for key in ("1", "X", "2")))
        sent_odds = odds if lock else {}
        if status == "cancelled":
            confirm = True
        else:
            status, home_score, away_score = "upcoming", 0, 0
            confirm = False
    return {
        "p_fixture_id": info["id"],
        "p_home_team": hebrew_name(home["name"]),
        "p_away_team": hebrew_name(away["name"]),
        "p_home_flag": flag_url(home["name"], home.get("logo")),
        "p_away_flag": flag_url(away["name"], away.get("logo")),
        "p_match_time": info["date"],
        "p_home_odds": sent_odds.get("1"),
        "p_draw_odds": sent_odds.get("X"),
        "p_away_odds": sent_odds.get("2"),
        "p_home_score": home_score,
        "p_away_score": away_score,
        "p_status": status,
        "p_round_name": league.get("round"),
        "p_lock_odds": lock,
        "p_confirm_result": confirm,
    }


def payload_from_game(game: dict, odds: dict[str, str | None] | None, *, lock_odds: bool, confirm: bool, status: str, home_score: int, away_score: int) -> dict:
    sent = odds if lock_odds else {}
    sent = sent or {}
    return {
        "p_fixture_id": game["fixture_id"],
        "p_home_team": game["home_team"],
        "p_away_team": game["away_team"],
        "p_home_flag": game.get("home_flag"),
        "p_away_flag": game.get("away_flag"),
        "p_match_time": game["match_time"],
        "p_home_odds": sent.get("1"),
        "p_draw_odds": sent.get("X"),
        "p_away_odds": sent.get("2"),
        "p_home_score": home_score,
        "p_away_score": away_score,
        "p_status": status,
        "p_round_name": game.get("round_name"),
        "p_lock_odds": lock_odds,
        "p_confirm_result": confirm,
    }


def push(db: Database, payload: dict) -> None:
    db.rpc("sync_game_result", payload)
    log.info(
        "Fixture %s %s vs %s -> %s %s-%s lock=%s confirm=%s",
        payload["p_fixture_id"],
        payload["p_home_team"],
        payload["p_away_team"],
        payload["p_status"],
        payload["p_home_score"],
        payload["p_away_score"],
        payload["p_lock_odds"],
        payload["p_confirm_result"],
    )


def load_fixtures(client: FootballClient, db: Database, today) -> tuple[int, list[dict]] | None:
    key = f"fixtures:{today.isoformat()}"
    cached = db.rpc("read_api_cache", {"p_key": key})
    if isinstance(cached, dict) and isinstance(cached.get("fixtures"), list):
        if not cached["fixtures"]:
            log.info("Today's fixture list is already stored and it is empty.")
            return None
        log.info("Using the fixture list already stored for %s.", today.isoformat())
        return int(cached["season"]), cached["fixtures"]
    start = (today - timedelta(days=1)).isoformat()
    end = (today + timedelta(days=45)).isoformat()
    seasons = []
    for season in (today.year, today.year - 1, today.year - 2, 2024, 2023, 2022):
        if season not in seasons:
            seasons.append(season)
    for season in seasons:
        fixtures = client.get_pages(
            "/fixtures",
            {"league": LEAGUE_ID, "season": season, "from": start, "to": end},
            "fixtures",
        )
        if fixtures is None:
            message = str(client.last_error or "").lower()
            if "suspended" in message or "token" in message or "key" in message:
                log.warning("Sports API account cannot be used. Stopping so the reserved requests stay unused.")
                client.stopped = True
                db.rpc("write_api_cache", {"p_key": key, "p_payload": {"season": None, "fixtures": []}})
                return None
            if "season" in message or "plan" in message:
                continue
            if client.stopped:
                return None
            return None
        db.rpc("write_api_cache", {"p_key": key, "p_payload": {"season": season, "fixtures": fixtures}})
        if fixtures:
            log.info("Stored Nations League season %s (%s fixtures) for today.", season, len(fixtures))
            return season, fixtures
        log.info("Season %s is reachable and has no fixtures in today's window. Cached that result.", season)
        return None
    db.rpc("write_api_cache", {"p_key": key, "p_payload": {"season": None, "fixtures": []}})
    log.info("No Nations League fixtures were available in today's window. The empty result is cached, so later runs today will not call the sports API for the fixture list.")
    return None


def upsert_catalogue(db: Database, fixtures: list[dict]) -> int:
    failures = 0
    for fixture in fixtures:
        fixture_id = (fixture.get("fixture") or {}).get("id")
        if not fixture_id or int(fixture_id) >= 900000:
            continue
        payload = build_payload(fixture, None)
        if not payload:
            continue
        try:
            push(db, payload)
        except RuntimeError:
            failures += 1
            log.exception("Could not store fixture %s", fixture_id)
    return failures


def rounds_ready_for_odds(games: list[dict], now: datetime) -> dict[str, list[dict]]:
    groups: dict[str, list[dict]] = {}
    for game in games:
        if game.get("odds_locked") or game.get("status") != "upcoming" or not game.get("match_time"):
            continue
        kick = parse_time(game["match_time"])
        if kick <= now:
            continue
        key = game.get("round_name") or kick.date().isoformat()
        groups.setdefault(key, []).append(game)
    ready: dict[str, list[dict]] = {}
    for key, rows in groups.items():
        earliest = min(parse_time(row["match_time"]) for row in rows)
        if now >= earliest - timedelta(hours=24) and now < earliest:
            ready[key] = rows
    return ready


def lock_odds(client: FootballClient, db: Database, season: int, games: list[dict], now: datetime) -> int:
    failures = 0
    for round_name, rows in rounds_ready_for_odds(games, now).items():
        dates = sorted({parse_time(row["match_time"]).date().isoformat() for row in rows})
        by_fixture: dict[int, dict[str, str | None]] = {}
        for day in dates:
            cache_key = f"odds:{season}:{round_name}:{day}"
            cached = db.rpc("read_api_cache", {"p_key": cache_key})
            rows_for_day = cached if isinstance(cached, list) else None
            if rows_for_day is None:
                rows_for_day = client.get_pages(
                    "/odds",
                    {"league": LEAGUE_ID, "season": season, "bookmaker": BET365_ID, "date": day},
                    "odds",
                )
                if rows_for_day is None:
                    return failures
                db.rpc("write_api_cache", {"p_key": cache_key, "p_payload": rows_for_day})
            for row in rows_for_day:
                fixture_id = (row.get("fixture") or {}).get("id")
                parsed = extract_1x2(row.get("bookmakers") or [])
                if fixture_id and parsed:
                    by_fixture[int(fixture_id)] = parsed
        for game in rows:
            parsed = by_fixture.get(int(game["fixture_id"]))
            if not parsed:
                continue
            payload = payload_from_game(
                game, parsed, lock_odds=True, confirm=False, status="upcoming", home_score=0, away_score=0,
            )
            try:
                push(db, payload)
            except RuntimeError:
                failures += 1
                log.exception("Could not lock odds for fixture %s", game["fixture_id"])
    return failures


def confirm_results(client: FootballClient, db: Database, games: list[dict], now: datetime) -> int:
    due = []
    for game in games:
        if game.get("result_confirmed") or game.get("status") in {"finished", "cancelled"}:
            continue
        if not game.get("fixture_id") or int(game["fixture_id"]) >= 900000 or not game.get("match_time"):
            continue
        if now >= parse_time(game["match_time"]) + timedelta(minutes=105):
            due.append(game)
    failures = 0
    for offset in range(0, len(due), 20):
        chunk = due[offset:offset + 20]
        body = client.get("/fixtures", {"ids": "-".join(str(game["fixture_id"]) for game in chunk)}, "results")
        if body is None:
            return failures
        by_id = {
            int((row.get("fixture") or {}).get("id")): row
            for row in body.get("response") or []
            if (row.get("fixture") or {}).get("id")
        }
        for game in chunk:
            fixture = by_id.get(int(game["fixture_id"]))
            if not fixture:
                continue
            payload = build_payload(fixture, None, confirm=True)
            if not payload:
                continue
            try:
                push(db, payload)
            except RuntimeError:
                failures += 1
                log.exception("Could not confirm fixture %s", game["fixture_id"])
    return failures


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

    db = Database(url, service_key)
    client = FootballClient(api_key, db)
    now = datetime.now(timezone.utc)
    chosen = load_fixtures(client, db, now.date())
    failures = 0
    if chosen:
        season, fixtures = chosen
        failures += upsert_catalogue(db, fixtures)
        if not client.stopped:
            failures += lock_odds(client, db, season, db.games(), now)
    if not client.stopped:
        failures += confirm_results(client, db, db.games(), now)
    if failures:
        log.error("%s database updates failed.", failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
