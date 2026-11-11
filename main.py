"""Sync five leagues and settle 90-minute results.

Each daily run calls the sports API once per league and never per match.
Bets are graded only from regular-time fulltime goals. Extra time and
penalties never change the stored score or a ticket's outcome.

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
LEAGUES = (
    (283, "israel"),
    (2, "ucl"),
    (140, "spain"),
    (39, "england"),
    (5, "nations"),
)
FIXTURE_LOOKAHEAD_DAYS = 7
ODDS_ENDPOINT = "/football-event-odds"
DEFAULT_ODDS_COUNTRY = "UK"
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

    def update_game_odds(self, fixture_id: int | str, prices: dict[str, str]) -> None:
        """Update only the three odds columns; do not pass through the result-locking RPC."""
        response = requests.patch(
            f"{self.url}/rest/v1/games",
            headers={**self.headers, "Prefer": "return=minimal"},
            params={"fixture_id": f"eq.{fixture_id}"},
            json={
                "home_odds": prices["1"],
                "draw_odds": prices["X"],
                "away_odds": prices["2"],
                "odds_locked": True,
            },
            timeout=40,
        )
        if response.status_code >= 300:
            raise RuntimeError(
                f"odds update failed for fixture {fixture_id}: "
                f"HTTP {response.status_code} {response.text[:240]}"
            )


def sports_connection(api_key: str) -> tuple[str, dict[str, str]]:
    provider = os.environ.get("SPORTS_API_PROVIDER", "rapidapi").strip().lower()
    if provider == "apisports":
        return API_BASE, {"x-apisports-key": api_key}
    return f"https://{RAPIDAPI_HOST}", {
        "x-rapidapi-key": api_key,
        "x-rapidapi-host": RAPIDAPI_HOST,
    }


class FootballClient:
    def __init__(self, api_key: str, db: Database):
        self.db = db
        self.stopped = False
        self.emergency = False
        self.last_error = None
        self.base, headers = sports_connection(api_key)
        self.session = requests.Session()
        self.session.headers.update(headers)

    def get(self, path: str, params: dict, purpose: str) -> dict | None:
        if self.stopped:
            return None
        self.last_error = None
        allowed = self.db.rpc("reserve_api_requests", {"p_count": 1, "p_emergency": self.emergency})
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
    """Extract only the full-time 1X2 market from the observed Smart API shapes."""
    root = ((payload or {}).get("response") or {}).get("odds") or {}
    inner = root.get("odds") if isinstance(root, dict) else None
    if not isinstance(inner, dict):
        return None

    markets: list[dict] = []
    markets.extend(item for item in inner.get("matchfactMarkets") or [] if isinstance(item, dict))
    for tab in inner.get("oddsTabMarkets") or []:
        if isinstance(tab, dict):
            markets.extend(item for item in tab.get("markets") or [] if isinstance(item, dict))

    for market in markets:
        header = str(market.get("header") or "").strip().lower()
        # Smart API has returned the market identifier in more than one field.
        translation = str(
            market.get("headerTranslationKey")
            or (market.get("fotMobMarketTypeId") or {}).get("translationKey")
            or ""
        ).strip().lower()
        if header != "full time result" and translation != "who_will_win":
            continue

        odds: dict[str, str | None] = {"1": None, "X": None, "2": None}
        for selection in market.get("selections") or []:
            if not isinstance(selection, dict):
                continue
            label = str(selection.get("name") or "").strip().lower()
            price = clamp_odd(selection.get("oddsDecimal"))
            if label == "1":
                odds["1"] = price
            elif label in {"x", "draw"}:
                odds["X"] = price
            elif label == "2":
                odds["2"] = price
        if all(odds.values()):
            return odds

    # Older Smart API responses sometimes expose only the resolved market.
    resolved = inner.get("resolvedOddsMarket")
    if isinstance(resolved, dict):
        odds = {"1": None, "X": None, "2": None}
        for selection in resolved.get("selections") or []:
            if not isinstance(selection, dict):
                continue
            label = str(selection.get("name") or "").strip().lower()
            price = clamp_odd(selection.get("oddsDecimal"))
            if label == "1":
                odds["1"] = price
            elif label in {"x", "draw"}:
                odds["X"] = price
            elif label == "2":
                odds["2"] = price
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


def tag_round(code: str, name: str | None) -> str:
    label = (name or "").strip()
    return f"{code}|{label}" if label else code


def odds_from_value(value) -> dict[str, str | None] | None:
    if not isinstance(value, dict):
        return None
    parsed = extract_1x2({"response": {"odds": value}})
    if parsed:
        return parsed
    home = clamp_odd(value.get("1") or value.get("home") or value.get("home_win"))
    draw = clamp_odd(value.get("X") or value.get("x") or value.get("draw"))
    away = clamp_odd(value.get("2") or value.get("away") or value.get("away_win"))
    if home and draw and away:
        return {"1": home, "X": draw, "2": away}
    return None


def extract_event_odds(payload: dict | None) -> dict[str, str | None] | None:
    """Extract the Bet365 1-X-2 market from Smart API's football-event-odds response."""
    if not isinstance(payload, dict):
        return None
    response = payload.get("response")
    if not isinstance(response, dict):
        return None
    provider = response.get("odds")
    if not isinstance(provider, dict):
        return None

    # Smart API returns 1X2 in two observed shapes:
    # 1) response.odds.odds.resolvedOddsMarket.selections
    # 2) response.odds.odds.matchfactMarkets / oddsTabMarkets
    # Parse the market-based shapes first; extract_1x2 filters specifically
    # for "Full Time Result" / "who_will_win" so other markets are ignored.
    parsed = extract_1x2({"response": {"odds": provider}})
    if parsed:
        return parsed

    market_container = provider.get("odds")
    if not isinstance(market_container, dict):
        return None
    market = market_container.get("resolvedOddsMarket")
    if not isinstance(market, dict):
        return None
    selections = market.get("selections")
    if not isinstance(selections, list):
        return None

    prices: dict[str, str | None] = {"1": None, "X": None, "2": None}
    for selection in selections:
        if not isinstance(selection, dict):
            continue
        name = str(selection.get("name") or "").strip().upper()
        if name in prices:
            prices[name] = clamp_odd(selection.get("oddsDecimal"))
    return prices if all(prices.values()) else None


def refresh_game_odds(client: FootballClient, db: Database, game: dict, now: datetime,
                      country_code: str, force: bool = False) -> bool:
    fixture_id = game.get("fixture_id")
    kickoff = game.get("match_time")
    if not fixture_id or not kickoff:
        return False
    if str(game.get("status") or "upcoming").lower() not in {"upcoming", "ns", "not started"}:
        return False
    if parse_time(kickoff) <= now:
        return False

    cache_key = f"event-odds:{fixture_id}:{now.date().isoformat()}:{country_code}"
    if not force:
        cached = db.rpc("read_api_cache", {"p_key": cache_key})
        if isinstance(cached, dict) and cached.get("_odds_checked") is True:
            cached_prices = cached.get("odds")
            # A successful 1X2 result is stable enough to keep for the day.
            if isinstance(cached_prices, dict) and all(cached_prices.get(k) for k in ("1", "X", "2")):
                return False
            # An empty result is not permanent: bookmakers often publish odds later.
            # Retry after six hours. Legacy cache entries without checked_at are retried.
            checked_at = cached.get("checked_at")
            if checked_at:
                try:
                    checked_time = parse_time(str(checked_at))
                    if now - checked_time < timedelta(hours=6):
                        return False
                except (TypeError, ValueError):
                    pass

    result = client.get(ODDS_ENDPOINT, {"eventid": str(fixture_id), "countrycode": country_code}, "odds")
    if result is None:
        return False
    prices = extract_event_odds(result)
    # Cache empty responses temporarily, not for the entire day: odds may appear later.
    db.rpc("write_api_cache", {
        "p_key": cache_key,
        "p_payload": {"_odds_checked": True, "checked_at": now.isoformat(), "odds": prices},
    })
    if not prices:
        log.info("No 1X2 odds currently available for fixture %s.", fixture_id)
        return False

    # Update only the odds columns directly. The result-sync RPC may intentionally
    # lock odds after their first write, which would block subsequent daily refreshes.
    db.update_game_odds(fixture_id, prices)
    log.info("Updated 1X2 odds for fixture %s: %s / %s / %s", fixture_id, prices["1"], prices["X"], prices["2"])
    return True


def in_board_window(kickoff: str, now: datetime) -> bool:
    kick = parse_time(kickoff)
    return now - timedelta(days=2) <= kick <= now + timedelta(days=FIXTURE_LOOKAHEAD_DAYS)


def should_confirm(state: str, kickoff: str, now: datetime) -> bool:
    kick = parse_time(kickoff)
    if state == "cancelled":
        return now >= kick
    if state == "finished":
        return now >= kick + timedelta(minutes=105)
    return False


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


def payload_from_match(round_name: str, match: dict, *, confirm: bool = False, odds: dict[str, str | None] | None = None) -> dict | None:
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
    prices = None if confirm else odds
    if prices and not all(prices.get(key) for key in ("1", "X", "2")):
        prices = None
    return {
        "p_fixture_id": int(fixture_id),
        "p_home_team": hebrew_name(home["name"]),
        "p_away_team": hebrew_name(away["name"]),
        "p_home_flag": flag_url(home["name"], None),
        "p_away_flag": flag_url(away["name"], None),
        "p_match_time": kickoff,
        "p_home_odds": None if prices is None else prices.get("1"),
        "p_draw_odds": None if prices is None else prices.get("X"),
        "p_away_odds": None if prices is None else prices.get("2"),
        "p_home_score": home_score,
        "p_away_score": away_score,
        "p_status": "cancelled" if state == "cancelled" else "finished" if confirm and state == "finished" else "upcoming",
        "p_round_name": round_name,
        "p_lock_odds": prices is not None,
        "p_confirm_result": confirm,
    }


def rapid_row(code: str, round_name: str, match: dict, now: datetime) -> dict | None:
    if not isinstance(match, dict):
        return None
    kickoff = (match.get("status") or {}).get("utcTime")
    if not kickoff or not in_board_window(kickoff, now):
        return None
    if "women" in round_name.lower():
        return None
    state = finished_state(match.get("status") or {})
    if state == "extra":
        return None
    confirm = should_confirm(state, kickoff, now)
    odds = None if confirm else odds_from_value(match.get("odds") if isinstance(match.get("odds"), dict) else None)
    return payload_from_match(round_name, match, confirm=confirm, odds=odds)


def api_row(code: str, fixture: dict, now: datetime) -> dict | None:
    info = fixture.get("fixture") or {}
    kickoff = info.get("date")
    if not kickoff or not in_board_window(kickoff, now):
        return None
    league = fixture.get("league") or {}
    round_name = tag_round(code, league.get("round") or league.get("name"))
    if "women" in round_name.lower():
        return None
    odds = odds_from_value(fixture.get("odds") if isinstance(fixture.get("odds"), dict) else None)
    built = build_payload(fixture, odds, lock_odds=bool(odds), confirm=False)
    if not built:
        return None
    built["p_round_name"] = round_name
    mapped = map_status((info.get("status") or {}).get("short") or "NS", fixture.get("score") or {}, fixture.get("goals") or {})
    if mapped is None:
        return None
    state, _, _ = mapped
    if state == "live":
        return built
    if should_confirm("finished" if state == "finished" else "cancelled" if state == "cancelled" else "upcoming", kickoff, now):
        confirmed = build_payload(fixture, None, lock_odds=False, confirm=True)
        if confirmed:
            confirmed["p_round_name"] = round_name
            return confirmed
    return built


def rows_from_payload(payload: dict | None, code: str, now: datetime) -> list[dict]:
    body = (payload or {}).get("response")
    items: list = []
    if isinstance(body, list):
        items = body
    elif isinstance(body, dict):
        for key in ("matches", "fixtures"):
            if isinstance(body.get(key), list):
                items = body[key]
                break
    rows: list[dict] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        if isinstance(item.get("matches"), list):
            name = tag_round(code, item.get("name"))
            for match in item["matches"]:
                built = rapid_row(code, name, match, now)
                if built:
                    rows.append(built)
            continue
        if item.get("fixture") and item.get("teams"):
            built = api_row(code, item, now)
            if built:
                rows.append(built)
            continue
        if item.get("home") and item.get("away"):
            built = rapid_row(code, code, item, now)
            if built:
                rows.append(built)
    return rows


def load_league(client: FootballClient, db: Database, league_id: int, code: str, now: datetime) -> list[dict]:
    cache_key = f"league-bundle:{league_id}:{now.date().isoformat()}"
    cached = db.rpc("read_api_cache", {"p_key": cache_key})
    if isinstance(cached, dict) and "response" in cached:
        return rows_from_payload(cached, code, now)
    if client.stopped:
        return []
    if RAPIDAPI_HOST in client.base:
        payload = client.get("/football-get-all-matches-by-league", {"leagueid": league_id}, "league")
    else:
        season = now.year if now.month >= 7 else now.year - 1
        payload = client.get(
            "/fixtures",
            {
                "league": league_id,
                "season": season,
                "from": (now.date() - timedelta(days=2)).isoformat(),
                "to": (now.date() + timedelta(days=FIXTURE_LOOKAHEAD_DAYS)).isoformat(),
            },
            "league",
        )
    if payload is None:
        message = str(client.last_error or "").lower()
        if "suspended" in message or "token" in message or "key" in message or "subscribed" in message:
            log.warning("Sports API account cannot be used. Stopping so the reserved requests stay unused.")
            client.stopped = True
        return []
    db.rpc("write_api_cache", {"p_key": cache_key, "p_payload": payload})
    return rows_from_payload(payload, code, now)


def upsert_catalogue(db: Database, fixtures: list[dict]) -> int:
    failures = 0
    for payload in fixtures:
        try:
            push(db, payload)
        except RuntimeError:
            failures += 1
            log.exception("Could not store fixture %s", payload.get("p_fixture_id"))
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
    fixtures: list[dict] = []
    for league_id, code in LEAGUES:
        fixtures.extend(load_league(client, db, league_id, code, now))
    log.info("League bundle has %s matches from %s league calls at most.", len(fixtures), len(LEAGUES))
    failures = upsert_catalogue(db, fixtures) if fixtures else 0
    if failures:
        log.error("%s database updates failed.", failures)
        return 1

    # Refresh odds separately from fixture discovery. Each match is checked at most
    # once per UTC day unless FORCE_ODDS_REFRESH=true is set for a manual run.
    country_code = os.environ.get("ODDS_COUNTRY_CODE", DEFAULT_ODDS_COUNTRY).strip().upper()
    force_odds = os.environ.get("FORCE_ODDS_REFRESH", "false").strip().lower() in {"1", "true", "yes"}
    if RAPIDAPI_HOST in client.base:
        try:
            games = db.games()
            updated = 0
            for game in games:
                if client.stopped:
                    break
                if refresh_game_odds(client, db, game, now, country_code, force=force_odds):
                    updated += 1
            log.info("Odds refresh completed: %s matches updated; force=%s; country=%s.", updated, force_odds, country_code)
        except RuntimeError:
            log.exception("Odds refresh failed; fixture sync has already completed.")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
