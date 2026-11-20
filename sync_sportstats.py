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
    "hull": ("האל סיטי", 322),
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

# Hebrew names for Israeli clubs. Keep aliases here because SportStatsAPI
# alternates between short names, transliterations and full club names.
ISRAEL_CLUB_NAMES = {
    "hapoel tel aviv": "הפועל תל אביב",
    "hapoel tel-aviv": "הפועל תל אביב",
    "hapoel tel aviv fc": "הפועל תל אביב",
    "hapoel tel-aviv fc": "הפועל תל אביב",
    "maccabi petah tikva": "מכבי פתח תקווה",
    "maccabi petach tikva": "מכבי פתח תקווה",
    "maccabi petah tikva fc": "מכבי פתח תקווה",
    "maccabi petach tikva fc": "מכבי פתח תקווה",
    "beitar jerusalem": "בית״ר ירושלים",
    "beitar jerusalem fc": "בית״ר ירושלים",
    "fc ashdod": "מ.ס. אשדוד",
    "ashdod": "מ.ס. אשדוד",
    "m.s. ashdod": "מ.ס. אשדוד",
    "moadon sport ashdod": "מ.ס. אשדוד",
    "hapoel beer sheva": "הפועל באר שבע",
    "hapoel be'er sheva": "הפועל באר שבע",
    "hapoel be er sheva": "הפועל באר שבע",
    "hapoel beer sheva fc": "הפועל באר שבע",
    "hapoel haifa": "הפועל חיפה",
    "hapoel haifa fc": "הפועל חיפה",
    "hapoel jerusalem": "הפועל ירושלים",
    "hapoel jerusalem fc": "הפועל ירושלים",
    "hapoel katamon": "הפועל ירושלים",
    "hapoel katamon jerusalem": "הפועל ירושלים",
    "hapoel petah tikva": "הפועל פתח תקווה",
    "hapoel petach tikva": "הפועל פתח תקווה",
    "hapoel petah tikva fc": "הפועל פתח תקווה",
    "ihud bnei sakhnin": "בני סכנין",
    "ihoud bnei sakhnin": "בני סכנין",
    "bnei sakhnin": "בני סכנין",
    "ihud bnei sakhnin fc": "בני סכנין",
    "ironi kiryat shmona": "עירוני קריית שמונה",
    "hapoel kiryat shmona": "עירוני קריית שמונה",
    "hapoel ironi kiryat shmona": "עירוני קריית שמונה",
    "ironi kiryat-shmona": "עירוני קריית שמונה",
    "ironi tiberias": "עירוני טבריה",
    "ironi tiberias fc": "עירוני טבריה",
    "maccabi bnei reineh": "מכבי בני ריינה",
    "maccabi bnei reineh fc": "מכבי בני ריינה",
    "maccabi bnei raina": "מכבי בני ריינה",
    "bnei reineh": "מכבי בני ריינה",
    "maccabi haifa": "מכבי חיפה",
    "maccabi haifa fc": "מכבי חיפה",
    "maccabi netanya": "מכבי נתניה",
    "maccabi netanya fc": "מכבי נתניה",
    "maccabi tel aviv": "מכבי תל אביב",
    "maccabi tel-aviv": "מכבי תל אביב",
    "maccabi tel aviv fc": "מכבי תל אביב",
    "hapoel ramat gan": "הפועל רמת גן",
    "hapoel ramat gan fc": "הפועל רמת גן",
    "hapoel ramat-gan": "הפועל רמת גן",
    "hapoel kfar saba": "הפועל כפר סבא",
    "hapoel kfar-saba": "הפועל כפר סבא",
    "hapoel rishon lezion": "הפועל ראשון לציון",
    "hapoel rishon le zion": "הפועל ראשון לציון",
    "bnei yehuda": "בני יהודה",
    "bnei yehuda tel aviv": "בני יהודה",
    "hapoel acre": "הפועל עכו",
    "hapoel akko": "הפועל עכו",
    "hapoel afula": "הפועל עפולה",
    "hapoel nof hagalil": "הפועל נוף הגליל",
    "hapoel nazareth illit": "הפועל נוף הגליל",
    "hapoel umm al fahm": "הפועל אום אל פחם",
    "hapoel umm al-fahm": "הפועל אום אל פחם",
    "maccabi herzliya": "מכבי הרצליה",
    "maccabi herzelia": "מכבי הרצליה",
    "hapoel ramat hasharon": "הפועל רמת השרון",
    "hapoel ramat-hasharon": "הפועל רמת השרון",
    "hapoel raanana": "הפועל רעננה",
    "hapoel ra'anana": "הפועל רעננה",
    "hapoel kfar shalem": "הפועל כפר שלם",
    "kiryat yam": "מ.ס. קריית ים",
    "kiryat yam sc": "מ.ס. קריית ים",
    "maccabi ahi nazareth": "מכבי אחי נצרת",
    "maccabi ahy nazareth": "מכבי אחי נצרת",
}

# Independently verified club crests. Provider images remain the fallback for
# Israeli clubs not listed here (including promoted/relegated lower-division sides).
ISRAEL_CLUB_LOGOS = {
    "hapoel tel aviv": "https://assets.footylogos.com/logos/hapoel-tel-aviv/hapoel-tel-aviv-logo-footylogos.svg",
    "beitar jerusalem": "https://assets.footylogos.com/logos/beitar-jerusalem/beitar-jerusalem-logo-footylogos.svg",
    "fc ashdod": "https://assets.footylogos.com/logos/fc-ashdod/fc-ashdod-logo-footylogos.svg",
    "hapoel beer sheva": "https://assets.footylogos.com/logos/hapoel-beer-sheva/hapoel-beer-sheva-logo-footylogos.svg",
    "hapoel haifa": "https://assets.footylogos.com/logos/hapoel-haifa/hapoel-haifa-logo-footylogos.svg",
    "hapoel jerusalem": "https://assets.footylogos.com/logos/hapoel-jerusalem/hapoel-jerusalem-logo-footylogos.svg",
    "hapoel petah tikva": "https://assets.footylogos.com/logos/hapoel-petah-tikva/hapoel-petah-tikva-logo-footylogos.svg",
    "ihud bnei sakhnin": "https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg",
    "ironi kiryat shmona": "https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg",
    "ironi tiberias": "https://assets.footylogos.com/logos/ironi-tiberias/ironi-tiberias-logo-footylogos.svg",
    "maccabi bnei reineh": "https://assets.footylogos.com/logos/maccabi-bnei-reineh/maccabi-bnei-reineh-logo-footylogos.svg",
    "maccabi haifa": "https://assets.footylogos.com/logos/maccabi-haifa/maccabi-haifa-logo-footylogos.svg",
    "maccabi netanya": "https://assets.footylogos.com/logos/maccabi-netanya/maccabi-netanya-logo-footylogos.svg",
    "maccabi tel aviv": "https://assets.footylogos.com/logos/maccabi-tel-aviv/maccabi-tel-aviv-logo-footylogos.svg",
    "maccabi petah tikva": "https://media.api-sports.io/football/teams/4495.png",
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
    key = normalize(name)
    if key in ISRAEL_CLUB_NAMES:
        return ISRAEL_CLUB_NAMES[key]
    entry = CLUBS.get(key)
    return entry[0] if entry else hebrew_name(name)

def team_logo_url(team: dict[str, Any], name: str) -> str | None:
    # Verified mappings must win over provider images: provider logos have
    # previously been assigned to the wrong club (e.g. Hull City / Liverpool).
    key = normalize(name)
    if key in ISRAEL_CLUB_LOGOS:
        return ISRAEL_CLUB_LOGOS[key]
    if key in UCL_LOGOS:
        return f"https://a.espncdn.com/i/teamlogos/soccer/500/{UCL_LOGOS[key]}.png"
    # Official Málaga CF crest from LALIGA; do not use football-data ID 98
    # (that asset belongs to AC Milan).
    if key in {"malaga", "málaga", "malaga cf", "málaga cf"}:
        return "https://assets.laliga.com/assets/2019/06/07/xsmall/malaga.png"
    entry = CLUBS.get(key)
    if entry:
        return f"https://crests.football-data.org/{entry[1]}.png"
    # National-team flags are deterministic too; do not trust club-logo fields
    # returned alongside international fixtures.
    if key in FLAGS:
        return flag_url(name, None)
    # Unknown clubs may still use a provider-supplied HTTPS crest.
    for field in ("logo", "image", "badge", "crest", "logo_url", "image_url"):
        value = team.get(field)
        if isinstance(value, str) and value.startswith("https://"):
            return value
    return safe_team_flag(name)


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
        log.warning("Rejected fixture %s: missing home/away team name", code or "<no-code>")
        return None
    try:
        kickoff = datetime.fromisoformat(str(start).replace("Z", "+00:00"))
        if kickoff.tzinfo is None:
            return None
        home_code = str(home.get("code") or "").strip()
        away_code = str(away.get("code") or "").strip()
        if not home_code or not away_code:
            log.warning("Rejected fixture %s: missing provider team ID", code)
            return None
        if home_code == away_code:
            log.error("Rejected fixture %s: home and away provider IDs are identical (%s)", code, home_code)
            return None
        if normalize(home_name) == normalize(away_name):
            log.error("Rejected fixture %s: home and away provider names are identical (%s)", code, home_name)
            return None
        home_display, away_display = team_display(home_name), team_display(away_name)
        if normalize(home_display) == normalize(away_display):
            log.error("Rejected fixture %s: translated home/away names collide (%s)", code, home_display)
            return None
    except (TypeError, ValueError):
        return None
    return {
        "code": code,
        "league_code": league["code"],
        "league_name": str(row.get("league_name") or league["name"]),
        "home_name": home_name,
        "away_name": away_name,
        "home_display": team_display(home_name),
        "away_display": team_display(away_name),
        "home_code": home_code,
        "away_code": away_code,
        "kickoff": kickoff.astimezone(timezone.utc).isoformat(),
    }


class SportStatsSync:
    def __init__(self) -> None:
        self.api_key = os.environ.get("SPORTSTATS_API_KEY", "").strip()
        self.supabase_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
        self.service_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
        if not self.supabase_url or not self.service_key:
            raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {self.api_key}", "Accept": "application/json"})
        self.db_headers = {
            "apikey": self.service_key,
            "Authorization": f"Bearer {self.service_key}",
            "Content-Type": "application/json",
        }
        self.api_calls = 0
        self.request_count = 0
        self.run_id: str | None = None

    @staticmethod
    def _response_payload(response: requests.Response) -> Any:
        try:
            payload = response.json()
        except ValueError:
            payload = response.text
        serialized = payload if isinstance(payload, str) else __import__("json").dumps(payload, ensure_ascii=False, default=str)
        if len(serialized) > 60000:
            return {
                "truncated": True,
                "original_chars": len(serialized),
                "preview": serialized[:60000],
            }
        return payload

    def _record_api_request(
        self,
        endpoint: str,
        params: dict[str, Any] | None,
        status: int,
        purpose: str,
        response_payload: Any,
        duration_ms: int,
    ) -> None:
        self.request_count += 1
        try:
            requests.post(
                f"{self.supabase_url}/rest/v1/rpc/log_api_request",
                headers=self.db_headers,
                json={
                    "p_endpoint": endpoint,
                    "p_params": params or {},
                    "p_status": status,
                    "p_purpose": purpose,
                    "p_response": response_payload,
                    "p_duration_ms": duration_ms,
                    "p_run_id": self.run_id,
                },
                timeout=12,
            ).raise_for_status()
        except Exception as exc:
            # Logging must never turn a successful data sync into a failed sync.
            log.error("Could not write API request report for %s: %s", endpoint, str(exc)[:300])

    def _request(
        self,
        method: str,
        url: str,
        *,
        purpose: str,
        params: dict[str, Any] | None = None,
        json_body: dict[str, Any] | None = None,
        headers: dict[str, str] | None = None,
        session: requests.Session | None = None,
        provider: bool = False,
    ) -> requests.Response:
        started = datetime.now(timezone.utc)
        clock = __import__("time").monotonic()
        try:
            client = session or requests
            response = client.request(
                method,
                url,
                headers=headers,
                params=params,
                json=json_body,
                timeout=35,
            )
        except Exception as exc:
            duration = int((__import__("time").monotonic() - clock) * 1000)
            self._record_api_request(
                url, params or json_body, 0, purpose,
                {"error": f"{type(exc).__name__}: {str(exc)[:2000]}"}, duration,
            )
            raise
        duration = int((__import__("time").monotonic() - clock) * 1000)
        if provider:
            self.api_calls += 1
        payload = self._response_payload(response)
        self._record_api_request(
            response.url, params or json_body, response.status_code,
            purpose, payload, duration,
        )
        return response

    def begin_run(self, purpose: str) -> None:
        trigger = os.environ.get("GITHUB_EVENT_NAME", "manual")
        run_number = os.environ.get("GITHUB_RUN_ID")
        if run_number:
            trigger = f"{trigger} · GitHub run {run_number}"
        response = requests.post(
            f"{self.supabase_url}/rest/v1/rpc/start_api_sync_run",
            headers=self.db_headers,
            json={"p_purpose": purpose, "p_trigger_source": trigger},
            timeout=20,
        )
        if response.status_code >= 300:
            raise RuntimeError(f"Could not start sync run: HTTP {response.status_code}: {response.text[:500]}")
        self.run_id = str(response.json()).strip('"')
        if not self.run_id:
            raise RuntimeError("Supabase did not return a sync run ID")

    def finish_run(
        self,
        status: str,
        summary: dict[str, Any] | None = None,
        error: str | None = None,
    ) -> None:
        if not self.run_id:
            return
        response = requests.post(
            f"{self.supabase_url}/rest/v1/rpc/finish_api_sync_run",
            headers=self.db_headers,
            json={
                "p_run_id": self.run_id,
                "p_status": status,
                "p_summary": {
                    **(summary or {}),
                    "provider_requests": self.api_calls,
                    "total_requests": self.request_count,
                },
                "p_error": error,
                "p_request_count": self.request_count,
            },
            timeout=20,
        )
        if response.status_code >= 300:
            log.error("Could not finalize sync run %s: HTTP %s %s", self.run_id, response.status_code, response.text[:500])

    def fetch_league(self, league_code: str, start: str, end: str) -> list[dict[str, Any]]:
        if self.api_key in PLACEHOLDERS:
            raise RuntimeError("SPORTSTATS_API_KEY is missing or still contains its placeholder")
        # Exactly one list request per league. No retries and no detail endpoint calls.
        params = {"league_id": league_code, "date_from": start, "date_to": end,
                  "limit": 100, "order": "asc"}
        response = self._request(
            "GET", f"{API_BASE}/soccer/matches",
            params=params,
            purpose=f"SportStatsAPI · שליפת משחקים · {league_code} · {start} עד {end}",
            session=self.session,
            provider=True,
        )
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

    def rpc(
        self,
        name: str | dict[str, Any],
        payload: dict[str, Any] | None = None,
        purpose: str | None = None,
    ) -> Any:
        # Preserve the concise fixture-upsert call while supporting quota and result RPCs.
        if payload is None:
            rpc_name = "upsert_sportstats_fixture"
            rpc_payload = name
        else:
            rpc_name = str(name)
            rpc_payload = payload
        response = self._request(
            "POST",
            f"{self.supabase_url}/rest/v1/rpc/{rpc_name}",
            headers=self.db_headers,
            json_body=rpc_payload,
            purpose=purpose or f"Supabase RPC · {rpc_name}",
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
            allowed = self.rpc("reserve_api_requests", {"p_count": 1, "p_emergency": False}, purpose="שמירת מכסת API לפני פנייה לספק")
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
                }, purpose=f"שמירת משחק בלוח · {team_display(home)} נגד {team_display(away)}")
                imported += 1
                log.info("Fixture %s (%s): %s", match["code"], label, result)
        log.info("Fixture import complete: %s fixtures, %s provider requests", imported, self.api_calls)
        return imported

    def fetch_unconfirmed_games(self, now: datetime) -> list[dict[str, Any]]:
        # Keep every started, unconfirmed fixture in the polling set across
        # local midnight and delayed provider finalization. A fixture leaves
        # this set only after result_confirmed becomes true (or its status is
        # explicitly changed out of upcoming/live by the application).
        params = {
            "select": "id,sportstats_match_code,sportstats_league_code,match_time",
            "sportstats_match_code": "not.is.null",
            "sportstats_league_code": "not.is.null",
            "result_confirmed": "eq.false",
            "match_time": f"lte.{now.isoformat()}",
            "status": "in.(upcoming,live)",
            "order": "match_time.asc",
            "limit": "500",
        }
        response = self._request(
            "GET",
            f"{self.supabase_url}/rest/v1/games",
            headers=self.db_headers,
            params=params,
            purpose="Supabase · איתור משחקים חיים/שהסתיימו וממתינים לתוצאה",
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
            log.info("No started, unconfirmed SportStatsAPI-linked games; 0 provider requests.")
            return 0

        league_codes = sorted({str(g["sportstats_league_code"]) for g in games if g.get("sportstats_league_code")})
        league_lookup = {code: (label, name) for code, label, name in LEAGUES}
        known_codes = [code for code in league_codes if code in league_lookup]
        if not known_codes:
            log.info("No supported SportStatsAPI leagues among pending games; 0 provider requests.")
            return 0

        israel_today = now.astimezone(ZoneInfo("Asia/Jerusalem")).date()
        by_code = {str(g["sportstats_match_code"]): g for g in games}
        confirmed = 0

        for league_code in known_codes:
            # One list request per league containing started, unconfirmed
            # games. Include the oldest pending kickoff date through today so
            # a match is not lost merely because Israel passed midnight.
            league_games = [
                g for g in games
                if str(g.get("sportstats_league_code") or "") == league_code
            ]
            kickoff_dates = []
            for game in league_games:
                try:
                    kickoff = datetime.fromisoformat(
                        str(game["match_time"]).replace("Z", "+00:00")
                    )
                    if kickoff.tzinfo is not None:
                        kickoff_dates.append(kickoff.astimezone(
                            ZoneInfo("Asia/Jerusalem")
                        ).date())
                except (KeyError, TypeError, ValueError):
                    continue
            if not kickoff_dates:
                log.warning("Skipping %s: pending games have no valid kickoff date.", league_code)
                continue
            start = min(kickoff_dates).isoformat()
            end = israel_today.isoformat()

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
                    }, purpose=f"אישור תוצאה סופית · {match_code} · {score[0]}-{score[1]}")
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
                }, purpose=f"עדכון תוצאה חיה · {match_code} · {live[0]}-{live[1]}")
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
    purpose = "SportStatsAPI · יבוא משחקים עתידיים" if args.mode == "fixtures" else "SportStatsAPI · עדכון תוצאות ותוצאות חיות"
    sync.begin_run(purpose)
    try:
        if args.mode == "fixtures":
            if os.environ.get("GITHUB_EVENT_NAME") == "schedule":
                local_now = datetime.now(timezone.utc).astimezone(ZoneInfo("Asia/Jerusalem"))
                if local_now.hour != 6:
                    reason = "Outside the scheduled Israel 06:00 fixture import; no provider calls."
                    log.info(reason)
                    sync.finish_run("skipped", {"reason": reason})
                    return
            imported = sync.sync_fixtures(args.days)
            sync.finish_run("success", {"mode": args.mode, "fixtures_imported": imported})
        else:
            confirmed = sync.sync_results()
            sync.finish_run("success", {"mode": args.mode, "results_confirmed": confirmed})
    except Exception as exc:
        log.exception("SportStatsAPI sync run failed")
        sync.finish_run("failed", {"mode": args.mode}, f"{type(exc).__name__}: {str(exc)[:3500]}")
        raise


if __name__ == "__main__":
    main()
