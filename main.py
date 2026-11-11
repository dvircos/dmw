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
