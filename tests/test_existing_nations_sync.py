import unittest

from sync_existing_nations import matches_existing_game, result_payload


class ExistingNationsSyncTests(unittest.TestCase):
    def setUp(self):
        self.game = {
            "id": 12,
            "fixture_id": 5181796,
            "home_team": "טורקיה",
            "away_team": "בלגיה",
            "home_flag": "home.png",
            "away_flag": "away.png",
            "match_time": "2026-11-12T17:00:00+00:00",
            "round_name": "UEFA Nations League A Grp. 1",
        }
        self.row = {
            "p_fixture_id": 5181796,
            "p_home_team": "טורקיה",
            "p_away_team": "בלגיה",
            "p_match_time": "2026-11-12T17:00:00+00:00",
            "p_status": "upcoming",
            "p_confirm_result": False,
            "p_home_score": 0,
            "p_away_score": 0,
        }

    def test_existing_provider_id_teams_and_kickoff_must_match(self):
        self.assertTrue(matches_existing_game(self.game, self.row))
        wrong_id = {**self.row, "p_fixture_id": 123}
        wrong_team = {**self.row, "p_away_team": "צרפת"}
        wrong_time = {**self.row, "p_match_time": "2026-11-14T17:00:00+00:00"}
        self.assertFalse(matches_existing_game(self.game, wrong_id))
        self.assertFalse(matches_existing_game(self.game, wrong_team))
        self.assertFalse(matches_existing_game(self.game, wrong_time))

    def test_only_confirmed_terminal_results_can_be_settled(self):
        self.assertIsNone(result_payload(self.game, self.row))
        final = {
            **self.row, "p_status": "finished", "p_confirm_result": True,
            "p_home_score": 2, "p_away_score": 1,
        }
        payload = result_payload(self.game, final)
        self.assertEqual(payload["p_fixture_id"], self.game["fixture_id"])
        self.assertEqual(payload["p_home_score"], 2)
        self.assertEqual(payload["p_away_score"], 1)
        self.assertEqual(payload["p_home_odds"], None)
        self.assertFalse(payload["p_lock_odds"])
        self.assertTrue(payload["p_confirm_result"])

    def test_cancelled_result_is_voidable(self):
        cancelled = {**self.row, "p_status": "cancelled", "p_confirm_result": True}
        self.assertEqual(result_payload(self.game, cancelled)["p_status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
