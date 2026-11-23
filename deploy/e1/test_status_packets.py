"""Receive-decoder identity tests; no SDK load or network participant."""
import unittest
from e1_status_packets import StatusDeduplicator, motor_packet


class StatusDeduplicatorTests(unittest.TestCase):
    def test_adjacent_and_late_exact_duplicates_do_not_advance_delivery(self):
        samples = StatusDeduplicator()
        self.assertTrue(samples.accept(10, 100, b"first raw CDR"))
        self.assertFalse(samples.accept(10, 100, b"first raw CDR"))
        self.assertTrue(samples.accept(11, 102, b"second raw CDR"))
        self.assertFalse(samples.accept(10, 100, b"first raw CDR"))
        self.assertEqual((samples.unique, samples.duplicates, samples.latest), (2, 2, 11))

    def test_changed_raw_payload_or_timestamp_is_a_conflict(self):
        for stamp, payload in ((101, b"raw CDR"), (100, b"changed CDR")):
            with self.subTest(stamp=stamp, payload=payload):
                samples = StatusDeduplicator()
                samples.accept(10, 100, b"raw CDR")
                with self.assertRaisesRegex(ValueError, "conflicting duplicate"):
                    samples.accept(10, stamp, payload)

    def test_real_sequence_gap_is_preserved_for_the_guard(self):
        samples = StatusDeduplicator()
        delivered = [seq for seq in (10, 10, 12, 12)
                     if samples.accept(seq, seq*2, bytes([seq]))]
        self.assertEqual(delivered, [10, 12])

    def test_unknown_old_sample_fails_after_bounded_cache_eviction(self):
        samples = StatusDeduplicator(capacity=2)
        for seq in (10, 11, 12):
            samples.accept(seq, seq*2, bytes([seq]))
        self.assertEqual(len(samples.recent), 2)
        with self.assertRaisesRegex(ValueError, "unknown old"):
            samples.accept(10, 20, bytes([10]))

    def test_first_receipt_is_kept_by_not_redelivering_a_duplicate(self):
        samples = StatusDeduplicator()
        delivered = [(arrival, source) for arrival, source in ((1000, 100), (9000, 100))
                     if samples.accept(10, source, b"same raw CDR")]
        self.assertEqual(delivered, [(1000, 100)])


class MotorFieldsTests(unittest.TestCase):
    def test_torque_uses_sdk_stride_without_replacing_missing_effort(self):
        values = [0.] * 171
        for i in range(24):
            values[6*i:6*i+6] = [i, i+.1, i+.2, -(i+.3), 0, 30]
        ids, packet = motor_packet(values, 4, 1000, 2000)
        self.assertEqual(ids, list(range(24)))
        self.assertEqual(packet["q"], [i+.1 for i in range(24)])
        self.assertEqual(packet["qd"], [i+.2 for i in range(24)])
        self.assertEqual(packet["tau"], [-(i+.3) for i in range(24)])
        self.assertEqual((packet["arrival_ns"], packet["source_ns"]), ("1000", "2000"))
        values[7*6+3] = float("nan")
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            motor_packet(values, 4, 1000, 2000)
        values[7*6+3] = 0.
        values[7*6] = 8
        with self.assertRaisesRegex(ValueError, "IDs"):
            motor_packet(values, 4, 1000, 2000)


if __name__ == "__main__":
    unittest.main()
