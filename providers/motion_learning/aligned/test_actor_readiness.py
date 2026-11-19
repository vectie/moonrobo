"""Bounded CPU replay control tests; no simulator or CUDA execution."""
from types import SimpleNamespace
import unittest

import torch

from .buffer import ReplayBuffer, require_actor_horizon
from .test_aligned_learning import transition


class ActorReadinessTests(unittest.TestCase):
    def setUp(self):
        torch.set_num_threads(1)
        self.motion = SimpleNamespace(clip_start=torch.tensor([0]), clip_end=torch.tensor([63]),
                                      clip_id=torch.zeros(64, dtype=torch.long))

    def test_boundary_ring_and_refill_preserve_candidate_rule(self):
        replay = ReplayBuffer(4, 1)
        replay.add(transition(31))
        replay.add(transition(32))
        self.assertEqual(replay.actor_start_status(self.motion, 32)['candidates'], 1)
        rng = torch.get_rng_state().clone()
        report = replay.ensure_actor_ready(self.motion, 32, 2, lambda _: self.fail('unexpected collect'))
        self.assertEqual(report['extra_collection_steps'], 0)
        torch.testing.assert_close(torch.get_rng_state(), rng, rtol=0, atol=0)
        starts, _ = replay.sample_starts(4, 3, motion=self.motion, horizon=32)
        self.assertTrue(bool((starts['f'] == 31).all()))
        for _ in range(4):
            replay.add(transition(62, step=0, done=True))
        steps = 0
        def collect(count):
            nonlocal steps
            for _ in range(count):
                steps += 1
                replay.add(transition(0 if steps >= 3 else 62, step=0, done=True))
        report = replay.ensure_actor_ready(self.motion, 32, 2, collect)
        self.assertEqual(report['extra_collection_steps'], 4)
        self.assertEqual(report['extra_physical_transitions'], 4)
        self.assertEqual(report['collection_step_budget'], 32)
        self.assertEqual(report['candidates'], 2)

    def test_two_rank_control_trace_and_peer_exhaustion(self):
        for success in (True, False):
            totals, initial_needs = [], []
            for ready in (True, False):
                replay = ReplayBuffer(8, 1)
                replay.add(transition(0 if ready else 62, step=0, done=True))
                steps, syncs, decisions = 0, 0, []
                def collect(count):
                    nonlocal steps
                    for _ in range(count):
                        steps += 1
                        frame = 0 if ready or (success and steps >= 4) else 62
                        replay.add(transition(frame, step=0, done=True))
                def any_need(local):
                    decisions.append(local)
                    return local or steps < 4 if success else True
                def sync():
                    nonlocal syncs
                    syncs += 1
                if success:
                    result = replay.ensure_actor_ready(self.motion, 32, 2, collect,
                                                       any_need=any_need, after_collect=sync)
                    self.assertEqual(result['extra_collection_steps'], 4)
                    self.assertEqual(syncs, 2)
                else:
                    with self.assertRaisesRegex(RuntimeError, 'finite collection budget'):
                        replay.ensure_actor_ready(self.motion, 32, 3, collect,
                                                  any_need=any_need, after_collect=sync)
                    self.assertEqual(steps, 32)
                    self.assertEqual(len(decisions), 12)
                    self.assertEqual(syncs, 11)
                    self.assertEqual(replay.actor_start_status(self.motion, 32)['candidates'],
                                     8 if ready else 0)
                totals.append(steps)
                initial_needs.append(decisions[0])
            self.assertEqual(totals, [4, 4] if success else [32, 32])
            self.assertEqual(initial_needs, [False, True])

    def test_impossible_catalog_rejected_and_mixed_catalog_preserved(self):
        motion = SimpleNamespace(clip_start=torch.tensor([0, 33]), clip_end=torch.tensor([31, 64]))
        with self.assertRaisesRegex(ValueError, 'H\\+1 states required'):
            require_actor_horizon(motion, 32)
        motion.clip_end[0] = 32
        before = motion.clip_end.clone()
        self.assertEqual(require_actor_horizon(motion, 32)['eligible_clips'], 1)
        torch.testing.assert_close(motion.clip_end, before, rtol=0, atol=0)


if __name__ == '__main__':
    unittest.main()
