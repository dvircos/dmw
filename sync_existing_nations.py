"""Sync results for the existing Nations League games only.

Uses the repository's configured RapidAPI/FotMob feed and the fixture_id
already stored on each app game. It never inserts or creates games.
"""
from __future__ import annotations

import logging
import os
from datetime import datetime, timezone

import requests

from main import Database, FootballClient, LEAGUES, ISRAEL_TZ, load_league

log = logging.getLogger("existing-nations-sync")


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def matches_existing_game(game: dict, row: dict, max_minutes: int = 180) -> bool:
    """Require the existing provider ID, both teams and kickoff to agree."""
    try:
        if int(game["fixture_id"]) != int(row["p_fixture_id"]):
            return False
        if str(game["home_team"]).strip().casefold() != str(row["p_home_team"]).strip().casefold():
            return False
        if str(game["away_team"]).strip().casefold() != str(row["p_away_team"]).strip().casefold():
            return False
        delta = abs((parse_time(game["match_time"]) - parse_time(row["p_match_time"])).total_seconds())
        return delta <= max_minutes * 60
    except (KeyError, TypeError, ValueError):
        return False


def result_payload(game: dict, row: dict) -> dict | None:
    """Build a settlement-only payload, preserving all app-owned match fields."""
    if not row.get("p_confirm_result") or row.get("p_status") not in {"finished", "cancelled"}:
        return None
    return {
        "p_fixture_id": int(game["fixture_id"]),
        "p_home_team": game["home_team"],
        "p_away_team": game["away_team"],
        "p_home_flag": game.get("home_flag"),
        "p_away_flag": game.get("away_flag"),
        "p_match_time": game["match_time"],
        "p_home_odds": None,
        "p_draw_odds": None,
        "p_away_odds": None,
        "p_home_score": int(row.get("p_home_score") or 0),
        "p_away_score": int(row.get("p_away_score") or 0),
        "p_status": row["p_status"],
        "p_round_name": game.get("round_name"),
        "p_lock_odds": False,
        "p_confirm_result": True,
    }


def get_existing_games(url: str, headers: dict) -> list[dict]:
    params = {
        "select": "id,fixture_id,home_team,away_team,home_flag,away_flag,match_time,round_name,status,result_confirmed",
        "fixture_id": "not.is.null",
        "status": "in.(upcoming,live)",
        "result_confirmed": "eq.false",
        "order": "match_time.asc",
        "limit": "500",
    }
    response = requests.get(f"{url.rstrip('/')}/rest/v1/games", headers=headers, params=params, timeout=40)
    response.raise_for_status()
    return response.json()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    if os.environ.get("GITHUB_EVENT_NAME") == "schedule":
        local_hour = datetime.now(timezone.utc).astimezone(ISRAEL_TZ).hour
        if local_hour not in {0, 20, 21, 22, 23}:
            log.info("Outside Israel 20:00-00:00 window; skipping provider calls.")
            return 0
    url = os.environ["SUPABASE_URL"].strip()
    service_key = os.environ["SUPABASE_SERVICE_ROLE_KEY"].strip()
    api_key = os.environ["API_KEY"].strip()
    if not url or not service_key or not api_key:
        raise RuntimeError("SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and API_KEY are required")

    db = Database(url, service_key)
    headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    games = get_existing_games(url, headers)
    if not games:
        log.info("No unsettled existing Nations League games found.")
        return 0

    def belongs(code: str, round_name: str) -> bool:
        name = str(round_name or "")
        return {
            "england": name == "הליגה האנגלית",
            "spain": name == "הליגה הספרדית",
            "ucl": name == "ליגת האלופות",
            "nations": name.startswith("ליגת האומות"),
            "israel": name == "ליגת העל",
        }.get(code, False)

    eligible_games = [g for g in games if any(belongs(code, g.get("round_name")) for _, code in LEAGUES)]
    if not eligible_games:
        log.info("No existing games belong to a configured results league.")
        return 0

    client = FootballClient(api_key, db)
    now = datetime.now(timezone.utc)
    by_fixture: dict[int, list[dict]] = {}
    fetched_leagues = []
    for league_id, code in LEAGUES:
        league_games = [g for g in eligible_games if belongs(code, g.get("round_name"))]
        if not league_games:
            continue
        rows = load_league(client, db, league_id, code, now)
        if client.stopped:
            error = client.last_error or {"message": "provider stopped the request"}
            raise RuntimeError(f"Sports API could not provide {code} data: {error}")
        if not rows:
            raise RuntimeError(f"Sports API returned no {code} fixtures; refusing to report a successful sync.")
        fetched_leagues.append(code)
        for row in rows:
            try:
                by_fixture.setdefault(int(row["p_fixture_id"]), []).append(row)
            except (KeyError, TypeError, ValueError):
                continue

    matched = 0
    settled = 0
    unmatched_ids = []
    for game in eligible_games:
        candidates = by_fixture.get(int(game["fixture_id"]), [])
        valid = [row for row in candidates if matches_existing_game(game, row)]
        if len(valid) != 1:
            unmatched_ids.append(int(game["id"]))
            log.warning(
                "Existing game %s not synced: fixture ID/team/time match count=%s",
                game["id"], len(valid),
            )
            continue
        matched += 1
        payload = result_payload(game, valid[0])
        if payload is None:
            continue
        result = db.rpc("sync_game_result", payload)
        settled += 1
        log.info("Existing Nations League result settled for game %s: %s", game["id"], result)

    try:
        db.rpc("log_api_request", {
            "p_endpoint": "/football-get-all-matches-by-league/verify-existing",
            "p_params": {
                "leagues_fetched": fetched_leagues,
                "app_games": len(eligible_games),
                "provider_rows": len(rows),
                "matched_existing_games": matched,
                "unmatched_game_ids": unmatched_ids,
                "settled_results": settled,
            },
            "p_status": 200,
            "p_purpose": "existing-multileague-results",
        })
    except RuntimeError:
        log.warning("Could not persist the mapping summary to the API request log.")

    log.info(
        "Existing multi-league sync complete (%s): %s matched, %s unmatched, %s results settled; no games created.",
        ",".join(fetched_leagues), matched, len(unmatched_ids), settled,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
