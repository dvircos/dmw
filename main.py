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
RAPIDAPI_HOST = "free-api-live-football-data.p.rapidapi.com"
NATIONS_LEAGUES = (9806, 9807, 9808, 9809)
FIXTURE_LOOKAHEAD_DAYS = 7
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
                "or": "(fixture_id.lt.900000,fixture_id.gte.910000)",
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
        return f"https://{RAPIDAPI_HOST}", {
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
            if payload.get("status") == "failed":
                self.last_error = payload.get("message") or payload
                log.warning("Sports API returned an error payload: %s", self.last_error)
                return None
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


def extract_1x2(payload: dict | None) -> dict[str, str | None] | None:
    odds = {"1": None, "X": None, "2": None}

    def take(label: str, value) -> None:
        key = label.strip().lower()
        parsed = clamp_odd(value)
        if key in {"1", "home", "home win"}:
            odds["1"] = odds["1"] or parsed
        elif key in {"x", "draw", "tie"}:
            odds["X"] = odds["X"] or parsed
        elif key in {"2", "away", "away win"}:
            odds["2"] = odds["2"] or parsed

    def walk(node, market: str) -> None:
        if isinstance(node, dict):
            market_name = str(node.get("marketName") or node.get("name") or node.get("title") or market).lower()
            label = str(node.get("name") or node.get("value") or node.get("outcome") or node.get("label") or "")
            price = node.get("oddsDecimal") or node.get("decimal") or node.get("odd") or node.get("price")
            if isinstance(price, dict):
                price = price.get("decimal") or price.get("odds")
            interesting = any(word in market_name for word in ("1x2", "full time", "fulltime", "match winner", "match result"))
            if interesting and label and not isinstance(price, (dict, list)):
                take(label, price)
            for child in node.values():
                walk(child, market_name)
        elif isinstance(node, list):
            for child in node:
                walk(child, market)

    walk((payload or {}).get("response") or {}, "")
    if all(odds.values()):
        return odds
    return None


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


def division_id(round_name: str | None) -> int | None:
    text = (round_name or "").lower()
    if "nations league a" in text:
        return 9806
    if "nations league b" in text:
        return 9807
    if "nations league c" in text:
        return 9808
    if "nations league d" in text:
        return 9809
    return None


def finished_state(status: dict) -> str:
    if status.get("cancelled"):
        return "cancelled"
    reason = status.get("reason") if isinstance(status.get("reason"), dict) else {}
    short = str((reason or {}).get("short") or "").upper()
    if short in {"AET", "PEN", "ET", "AP"}:
        return "extra"
    if status.get("finished") or short == "FT":
        return "finished"
    if status.get("started"):
        return "live"
    return "upcoming"


def payload_from_match(round_name: str, match: dict, *, confirm: bool = False) -> dict | None:
    home = match.get("home") or {}
    away = match.get("away") or {}
    status = match.get("status") or {}
    fixture_id = match.get("id")
    kickoff = status.get("utcTime")
    if not fixture_id or 900000 <= int(fixture_id) < 910000 or not kickoff or not home.get("name") or not away.get("name"):
        return None
    state = finished_state(status)
    if confirm:
        if state not in {"finished", "cancelled"}:
            return None
    elif state == "cancelled":
        confirm = True
    else:
        state = "upcoming"
    home_score = int(home.get("score") or 0) if confirm else 0
    away_score = int(away.get("score") or 0) if confirm else 0
    return {
        "p_fixture_id": int(fixture_id),
        "p_home_team": hebrew_name(home["name"]),
        "p_away_team": hebrew_name(away["name"]),
        "p_home_flag": flag_url(home["name"], None),
        "p_away_flag": flag_url(away["name"], None),
        "p_match_time": kickoff,
        "p_home_odds": None,
        "p_draw_odds": None,
        "p_away_odds": None,
        "p_home_score": home_score,
        "p_away_score": away_score,
        "p_status": "cancelled" if state == "cancelled" else "finished" if confirm and state == "finished" else "upcoming",
        "p_round_name": round_name,
        "p_lock_odds": False,
        "p_confirm_result": confirm,
    }


def matches_from_day(payload: dict | None) -> list[dict]:
    rows = []
    response = (payload or {}).get("response")
    groups = response if isinstance(response, list) else []
    for group in groups:
        if not isinstance(group, dict):
            continue
        round_name = group.get("name") or ""
        if "women" in round_name.lower() or "nations league" not in round_name.lower():
            continue
        for match in group.get("matches") or []:
            built = payload_from_match(round_name, match)
            if built:
                rows.append(built)
    return rows


def load_fixtures(client: FootballClient, db: Database, today) -> list[dict] | None:
    rows: list[dict] = []
    for offset in range(FIXTURE_LOOKAHEAD_DAYS):
        day = today + timedelta(days=offset)
        stamp = day.strftime("%Y%m%d")
        for league_id in NATIONS_LEAGUES:
            cache_key = f"live-fixtures:{league_id}:{stamp}"
            cached = db.rpc("read_api_cache", {"p_key": cache_key})
            if isinstance(cached, list):
                rows.extend(cached)
                continue
            if client.stopped:
                return rows or None
            payload = client.get(
                "/football-get-matches-by-date-and-league",
                {"date": stamp, "leagueid": league_id},
                "fixtures",
            )
            if payload is None:
                message = str(client.last_error or "").lower()
                if "suspended" in message or "token" in message or "key" in message or "subscribed" in message:
                    log.warning("Sports API account cannot be used. Stopping so the reserved requests stay unused.")
                    client.stopped = True
                return rows or None
            parsed = matches_from_day(payload)
            db.rpc("write_api_cache", {"p_key": cache_key, "p_payload": parsed})
            rows.extend(parsed)
    log.info("Nations League fixture list has %s matches in the next %s days.", len(rows), FIXTURE_LOOKAHEAD_DAYS)
    return rows


def upsert_catalogue(db: Database, fixtures: list[dict]) -> int:
    failures = 0
    for payload in fixtures:
        try:
            push(db, payload)
        except RuntimeError:
            failures += 1
            log.exception("Could not store fixture %s", payload.get("p_fixture_id"))
    return failures


def matches_for_odds(games: list[dict], now: datetime) -> list[dict]:
    window = []
    for game in games:
        if game.get("odds_locked") or game.get("status") != "upcoming" or not game.get("match_time"):
            continue
        kick = parse_time(game["match_time"])
        if now < kick <= now + timedelta(days=7):
            window.append(game)
    window.sort(key=lambda game: game["match_time"])
    return window


def lock_odds(client: FootballClient, db: Database, games: list[dict], now: datetime) -> int:
    failures = 0
    today = now.date().isoformat()
    for game in matches_for_odds(games, now):
        cache_key = f"odds:{game['fixture_id']}:{today}"
        cached = db.rpc("read_api_cache", {"p_key": cache_key})
        if isinstance(cached, dict) and "parsed" in cached:
            parsed = cached.get("parsed")
        else:
            if client.stopped:
                return failures
            payload = client.get("/football-event-odds", {"eventid": game["fixture_id"]}, "odds")
            if payload is None:
                return failures
            parsed = extract_1x2(payload)
            db.rpc("write_api_cache", {"p_key": cache_key, "p_payload": {"parsed": parsed}})
        if not parsed:
            continue
        update = payload_from_game(
            game, parsed, lock_odds=True, confirm=False, status="upcoming", home_score=0, away_score=0,
        )
        try:
            push(db, update)
        except RuntimeError:
            failures += 1
            log.exception("Could not lock odds for fixture %s", game["fixture_id"])
    return failures


def confirm_results(client: FootballClient, db: Database, games: list[dict], now: datetime) -> int:
    due_keys: dict[tuple[int, str], None] = {}
    for game in games:
        if game.get("result_confirmed") or game.get("status") in {"finished", "cancelled"}:
            continue
        if not game.get("fixture_id") or 900000 <= int(game["fixture_id"]) < 910000 or not game.get("match_time"):
            continue
        kick = parse_time(game["match_time"])
        if now < kick + timedelta(minutes=105):
            continue
        league_id = division_id(game.get("round_name"))
        if league_id is None:
            continue
        due_keys[(league_id, kick.strftime("%Y%m%d"))] = None
    failures = 0
    for league_id, stamp in due_keys:
        if client.stopped:
            return failures
        payload = client.get(
            "/football-get-matches-by-date-and-league",
            {"date": stamp, "leagueid": league_id},
            "results",
        )
        if payload is None:
            return failures
        response = payload.get("response")
        groups = response if isinstance(response, list) else []
        for group in groups:
            if not isinstance(group, dict):
                continue
            round_name = group.get("name") or ""
            for match in group.get("matches") or []:
                built = payload_from_match(round_name, match, confirm=True)
                if not built:
                    continue
                try:
                    push(db, built)
                except RuntimeError:
                    failures += 1
                    log.exception("Could not confirm fixture %s", built["p_fixture_id"])
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
    fixtures = load_fixtures(client, db, now.date())
    failures = 0
    if fixtures:
        failures += upsert_catalogue(db, fixtures)
        if not client.stopped:
            failures += lock_odds(client, db, db.games(), now)
    if not client.stopped:
        failures += confirm_results(client, db, db.games(), now)
    if failures:
        log.error("%s database updates failed.", failures)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
