import unittest

# Regression tests for API-Football status handling and request batching.

from sync_api_football import chunks, fixture_matches_existing_game, parse_api_result


def fixture(short, fulltime=None, goals=None):
    return {
        "fixture": {"id": 123, "status": {"short": short}},
        "score": {"fulltime": fulltime or {}},
        "goals": goals or {},
    }


class ResultMappingTests(unittest.TestCase):
    def test_full_time_uses_regular_time_score(self):
        self.assertEqual(parse_api_result(fixture("FT", {"home": 2, "away": 1})), ("finished", 2, 1))

    def test_after_extra_time_uses_90_minute_score_not_extra_time(self):
        item = fixture("AET", {"home": 1, "away": 1})
        item["score"]["extratime"] = {"home": 2, "away": 1}
        self.assertEqual(parse_api_result(item), ("finished", 1, 1))

    def test_penalties_use_regular_time_score(self):
        item = fixture("PEN", {"home": 0, "away": 0})
        item["score"]["penalty"] = {"home": 4, "away": 3}
        self.assertEqual(parse_api_result(item), ("finished", 0, 0))

    def test_extra_time_and_shootout_in_progress_are_not_final(self):
        self.assertEqual(parse_api_result(fixture("ET", goals={"home": 2, "away": 1})), ("live", 2, 1))
        self.assertEqual(parse_api_result(fixture("P", goals={"home": 2, "away": 1})), ("live", 2, 1))

    def test_half_time_is_live(self):
        self.assertEqual(parse_api_result(fixture("HT", goals={"home": 1, "away": 0})), ("live", 1, 0))

    def test_missing_final_score_is_ignored(self):
        self.assertIsNone(parse_api_result(fixture("FT")))

    def test_postponed_and_abandoned_are_not_auto_voided(self):
        self.assertIsNone(parse_api_result(fixture("PST")))
        self.assertIsNone(parse_api_result(fixture("ABD")))

    def test_cancelled_is_voidable(self):
        self.assertEqual(parse_api_result(fixture("CANC")), ("cancelled", 0, 0))

    def test_ids_are_batched_at_maximum_twenty(self):
        batches = list(chunks(list(range(45)), 20))
        self.assertEqual([len(batch) for batch in batches], [20, 20, 5])
        self.assertEqual(sum(batches, []), list(range(45)))

    def test_existing_nations_match_requires_same_teams_and_close_kickoff(self):
        game = {
            "home_team": "טורקיה", "away_team": "בלגיה",
            "match_time": "2026-11-12T17:00:00+00:00",
        }
        item = {
            "fixture": {"id": 999, "date": "2026-11-12T17:00:00+00:00"},
            "teams": {"home": {"name": "Turkey"}, "away": {"name": "Belgium"}},
        }
        self.assertTrue(fixture_matches_existing_game(game, item))

    def test_existing_nations_match_rejects_wrong_opponent_or_kickoff(self):
        game = {
            "home_team": "טורקיה", "away_team": "בלגיה",
            "match_time": "2026-11-12T17:00:00+00:00",
        }
        wrong_team = {
            "fixture": {"id": 999, "date": "2026-11-12T17:00:00+00:00"},
            "teams": {"home": {"name": "Turkey"}, "away": {"name": "France"}},
        }
        wrong_time = {
            "fixture": {"id": 999, "date": "2026-11-13T17:00:00+00:00"},
            "teams": {"home": {"name": "Turkey"}, "away": {"name": "Belgium"}},
        }
        self.assertFalse(fixture_matches_existing_game(game, wrong_team))
        self.assertFalse(fixture_matches_existing_game(game, wrong_time))


if __name__ == "__main__":
    unittest.main()
