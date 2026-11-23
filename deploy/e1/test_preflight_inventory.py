"""Receive-only inventory accepts endpoints without dynamic type metadata."""
import types
import unittest
from preflight import endpoint_summary


class InventoryTests(unittest.TestCase):
    def test_optional_type_identifier_is_preserved_as_unknown(self):
        ep = types.SimpleNamespace(topic_name="DCPSPublication", type_id=None)
        self.assertEqual(endpoint_summary(ep), dict(topic="DCPSPublication", type_id=None))

    def test_advertised_type_identifier_is_kept_exactly(self):
        ep = types.SimpleNamespace(topic_name="Robot_Status_Topic",
                                   type_id=types.SimpleNamespace(serialize=lambda: b"\x00\x07\xab"))
        self.assertEqual(endpoint_summary(ep), dict(topic="Robot_Status_Topic", type_id="0007ab"))


if __name__ == "__main__":
    unittest.main()
