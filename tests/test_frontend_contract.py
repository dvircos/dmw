import re
import unittest
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class IdParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []

    def handle_starttag(self, tag, attrs):
        self.ids.extend(value for key, value in attrs if key == "id")


class FrontendContractTests(unittest.TestCase):
    def test_html_ids_are_unique_and_app_references_exist(self):
        html = (ROOT / "index.html").read_text(encoding="utf-8")
        app = (ROOT / "js" / "app.js").read_text(encoding="utf-8")
        parser = IdParser()
        parser.feed(html)
        self.assertEqual(len(parser.ids), len(set(parser.ids)), "duplicate HTML id")
        html_ids = set(parser.ids)
        referenced = set(re.findall(r'\$\("([^"]+)"\)', app))
        self.assertEqual(referenced - html_ids, set(), "app.js references missing HTML ids")

    def test_active_games_and_archive_are_fetched_separately(self):
        app = (ROOT / "js" / "app.js").read_text(encoding="utf-8")
        self.assertIn('.in("status", ["upcoming", "live"])', app)
        self.assertIn('.in("status", ["finished", "cancelled"])', app)
        self.assertIn("async function loadMoreArchive()", app)

    def test_service_worker_never_returns_html_for_missing_assets(self):
        sw = (ROOT / "sw.js").read_text(encoding="utf-8")
        self.assertIn('request.mode === "navigate"', sw)
        self.assertIn('if (isNavigation)', sw)
        self.assertNotIn('hit || caches.match("./index.html")', sw)

    def test_result_sync_is_scheduled_every_30_minutes(self):
        workflow = (ROOT / ".github" / "workflows" / "sportstats-results.yml").read_text(encoding="utf-8")
        self.assertIn('cron: "*/30 * * * *"', workflow)

    def test_result_sync_only_checks_unconfirmed_games_scheduled_today_in_israel(self):
        sync = (ROOT / "sync_sportstats.py").read_text(encoding="utf-8")
        self.assertIn('local_date = now.astimezone(israel).date()', sync)
        self.assertIn('day_start = datetime.combine(local_date, time.min, tzinfo=israel)', sync)
        self.assertIn('day_end = datetime.combine(local_date + timedelta(days=1), time.min, tzinfo=israel)', sync)
        self.assertIn('"match_time": f"gte.{day_start.isoformat()}"', sync)
        self.assertIn('"and": f"(match_time.lt.{day_end.isoformat()})"', sync)
        self.assertIn('israel_today = now.astimezone(ZoneInfo("Asia/Jerusalem")).date().isoformat()', sync)
        self.assertIn("league_codes = sorted({str(g[\"sportstats_league_code\"]) for g in games", sync)

    def test_winner_odds_import_is_admin_guarded(self):
        migration = (ROOT / "migration_security_and_performance.sql").read_text(encoding="utf-8")
        self.assertIn("if not public.admin_is_admin() then", migration)
        self.assertIn("jsonb_array_length(p_matches) > 500", migration)


if __name__ == "__main__":
    unittest.main()
