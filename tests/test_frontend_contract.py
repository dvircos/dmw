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

    def test_result_sync_uses_supabase_cron_dispatch_not_github_schedule(self):
        workflow = (ROOT / ".github" / "workflows" / "sportstats-results.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("push:", workflow)
        self.assertNotIn("cron:", workflow)

    def test_result_sync_polls_started_unconfirmed_games_across_midnight(self):
        sync = (ROOT / "sync_sportstats.py").read_text(encoding="utf-8")
        self.assertIn('"match_time": f"lte.{now.isoformat()}"', sync)
        self.assertIn('"status": "in.(upcoming,live)"', sync)
        self.assertIn('"result_confirmed": "eq.false"', sync)
        self.assertNotIn("active_window_end", sync)
        self.assertNotIn("day_start = datetime.combine", sync)
        self.assertIn("league_codes = sorted({str(g[\"sportstats_league_code\"]) for g in games", sync)
        self.assertIn("start = min(kickoff_dates).isoformat()", sync)
        self.assertIn("end = israel_today.isoformat()", sync)
        self.assertIn("rows = self.fetch_league(league_code, start, end)", sync)


    def test_rtl_score_display_matches_the_visual_home_away_order(self):
        app = (ROOT / "js" / "app.js").read_text(encoding="utf-8")
        # In RTL grid layout, the first DOM column (home) is on the right.
        # The visible left-to-right score must therefore be away-home.
        self.assertIn("teams.append(home, score, away)", app)
        self.assertIn("${game.away_score} - ${game.home_score}", app)
        self.assertIn('[["1", game.home_odds], ["X", game.draw_odds], ["2", game.away_odds]]', app)
        self.assertIn('if (selection === "1") return Number(game.home_odds);', app)
        self.assertIn('return Number(game.away_odds);', app)

    def test_result_settlement_uses_provider_home_away_order_consistently(self):
        sync = (ROOT / "sync_sportstats.py").read_text(encoding="utf-8")
        migration = (ROOT / "migration_sportstats_results.sql").read_text(encoding="utf-8")
        self.assertIn("return hs, aws", sync)
        self.assertIn('"p_home_score": score[0]', sync)
        self.assertIn('"p_away_score": score[1]', sync)
        self.assertIn("p_home_score > v_game.away_score", migration)
        self.assertIn("p_home_score < v_game.away_score", migration)

    def test_winner_odds_import_is_admin_guarded(self):
        migration = (ROOT / "migration_security_and_performance.sql").read_text(encoding="utf-8")
        self.assertIn("if not public.admin_is_admin() then", migration)
        self.assertIn("jsonb_array_length(p_matches) > 500", migration)


if __name__ == "__main__":
    unittest.main()
