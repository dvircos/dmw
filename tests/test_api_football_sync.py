import unittest

from sync_api_football import chunks, parse_api_result


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


if __name__ == "__main__":
    unittest.main()
