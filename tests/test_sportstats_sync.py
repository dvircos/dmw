import unittest
from datetime import datetime, timezone

from sync_sportstats import LEAGUES, parse_match


class SportStatsParsingTests(unittest.TestCase):
    def test_confirmed_league_codes_are_fixed_and_unique(self):
        codes = [row[0] for row in LEAGUES]
        self.assertEqual(codes, ["l30", "l6t", "l46", "lml", "l3"])
        self.assertEqual(len(codes), len(set(codes)))

    def test_scheduled_match_is_normalized_from_list_response(self):
        row = {
            "code": "m907x", "status": "NS",
            "start_at": "2026-11-21T12:30:00Z",
            "league_name": "Premier League",
            "home_team": {"code": "t1", "name": "Manchester City"},
            "away_team": {"code": "t2", "display_name": "Fulham"},
        }
        result = parse_match(row, {"code": "l30", "label": "england", "name": "Premier League"})
        self.assertEqual(result["code"], "m907x")
        self.assertEqual(result["home_name"], "Manchester City")
        self.assertEqual(result["away_name"], "Fulham")
        self.assertEqual(result["kickoff"], "2026-11-21T12:30:00+00:00")

    def test_finished_matches_are_never_imported_as_fixtures(self):
        row = {"code": "m1", "status": "FT", "start_at": "2026-11-01T10:00:00Z",
               "home_team": {"code": "a", "name": "A"}, "away_team": {"code": "b", "name": "B"}}
        self.assertIsNone(parse_match(row, {"code": "l30", "label": "england", "name": "Premier League"}))

    def test_incomplete_or_timezone_naive_rows_are_rejected(self):
        league = {"code": "l30", "label": "england", "name": "Premier League"}
        self.assertIsNone(parse_match({"code": "m1", "status": "NS"}, league))
        row = {"code": "m1", "status": "NS", "start_at": "2026-11-21T12:30:00",
               "home_team": {"code": "a", "name": "A"}, "away_team": {"code": "b", "name": "B"}}
        self.assertIsNone(parse_match(row, league))

    def test_team_ids_are_required_for_deterministic_mapping(self):
        row = {"code": "m1", "status": "NS", "start_at": "2026-11-21T12:30:00Z",
               "home_team": {"name": "A"}, "away_team": {"code": "b", "name": "B"}}
        self.assertIsNone(parse_match(row, {"code": "l30", "label": "england", "name": "Premier League"}))


if __name__ == "__main__":
    unittest.main()
