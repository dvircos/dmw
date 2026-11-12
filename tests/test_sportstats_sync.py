import unittest
from datetime import datetime, timezone

from sync_sportstats import LEAGUES, SportStatsSync, parse_match


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


    def test_home_and_away_identity_must_be_distinct(self):
        league = {"code": "lml", "label": "nations", "name": "UEFA Nations League"}
        base = {"code": "m1", "status": "NS", "start_at": "2026-11-21T12:30:00Z",
                "home_team": {"code": "a", "name": "France"},
                "away_team": {"code": "b", "name": "Italy"}}
        self.assertIsNotNone(parse_match(base, league))
        self.assertIsNone(parse_match({**base, "away_team": {"code": "a", "name": "Italy"}}, league))
        self.assertIsNone(parse_match({**base, "away_team": {"code": "b", "name": "France"}}, league))

    def test_hebrew_translation_preserves_distinct_home_away_names(self):
        league = {"code": "lml", "label": "nations", "name": "UEFA Nations League"}
        row = {"code": "m2", "status": "NS", "start_at": "2026-11-21T12:30:00Z",
               "home_team": {"code": "fr", "name": "France"},
               "away_team": {"code": "it", "name": "Italy"}}
        result = parse_match(row, league)
        self.assertEqual(result["home_display"], "צרפת")
        self.assertEqual(result["away_display"], "איטליה")

    def test_club_crest_ids_are_unique_across_distinct_clubs(self):
        from sync_sportstats import CLUBS
        crest_owners = {}
        for alias, (hebrew, crest_id) in CLUBS.items():
            previous = crest_owners.get(crest_id)
            self.assertTrue(previous is None or previous == hebrew,
                            f"crest ID {crest_id} is shared by {previous} and {hebrew} (alias {alias})")
            crest_owners[crest_id] = hebrew

    def test_full_time_result_uses_regular_time_team_scores(self):
        row = {
            "status": "FT", "status_code": "final",
            "home_team": {"score": 0}, "away_team": {"score": 1},
            "full_time_score": "[0-1]",
            "periods": [{"period": "FT", "home": 0, "away": 1}],
        }
        self.assertEqual(SportStatsSync.final_score(row), (0, 1))

    def test_live_minute_and_halftime_scores_are_separate_from_final_results(self):
        minute_row = {"status": "52", "status_code": "live", "minute": 52,
                      "home_team": {"score": 1}, "away_team": {"score": 0}}
        halftime_row = {"status": "HT", "status_code": "halftime",
                        "home_team": {"score": 1}, "away_team": {"score": 1}}
        self.assertEqual(SportStatsSync.live_score(minute_row), (1, 0, 52, "52"))
        self.assertEqual(SportStatsSync.live_score(halftime_row), (1, 1, None, "HT"))
        self.assertIsNone(SportStatsSync.final_score(minute_row))
        self.assertIsNone(SportStatsSync.final_score(halftime_row))

    def test_scheduled_and_unknown_statuses_are_not_live(self):
        for status in ("NS", "TBD", "", "FT", "PST", "CANC"):
            row = {"status": status, "status_code": "scheduled",
                   "home_team": {"score": 0}, "away_team": {"score": 0}}
            self.assertIsNone(SportStatsSync.live_score(row))

    def test_ft_is_settled_from_canonical_soccer_status_even_if_status_code_differs(self):
        row = {"status": "FT", "status_code": "finished",
               "home_team": {"score": 2}, "away_team": {"score": 1}}
        self.assertEqual(SportStatsSync.final_score(row), (2, 1))

    def test_extra_time_and_unconfirmed_statuses_are_not_settled(self):
        for status, code in [("AET", "final"), ("PEN", "final"), ("2H", "live")]:
            row = {"status": status, "status_code": code,
                   "home_team": {"score": 2}, "away_team": {"score": 1},
                   "full_time_score": "[1-1]"}
            self.assertIsNone(SportStatsSync.final_score(row))

    def test_final_score_string_is_a_safe_fallback(self):
        row = {"status": "FT", "status_code": "final",
               "home_team": {}, "away_team": {}, "full_time_score": "[2-1]"}
        self.assertEqual(SportStatsSync.final_score(row), (2, 1))


if __name__ == "__main__":
    unittest.main()
