"""Episode-boundary, action-law and full-memory imagined-gradient checks."""
from pathlib import Path
import hashlib
import tempfile
import unittest

import numpy as np
import torch

from balance_features import BalanceKinematics, make_spec
from cpu_physics import PhysicsRuntime
from dynamics import ResidualDynamics
from full_body_reference import FullBodyReference, capture_frame, layout_for
from reference_actor import ReferenceActor, save_reference_actor
from reference_learning_study import baseline_record_ids, verify_reconstructed_cycle
from reference_learning import ReferenceModelReplay, actor_origin_indices, collect_episode, finite_returns, imagined_objective, join_batches, optimize_model_actor, ppo_advantages, restore_collected_batch, state_digest, take
from reference_task import ReferenceSchedule, ReferenceValue
from reference_tail_directions import PrefixOnlyValue
from reference_learning_export import load_behavior_actor


class ZeroValue(torch.nn.Module):
    def forward(self, state, *args):
        return torch.zeros(len(state))


class ReferenceLearningTest(unittest.TestCase):
    def setUp(self):
        scene = Path(__file__).resolve().parents[2]/"target/mujoco_menagerie/unitree_g1/scene_mjx.xml"
        self.rt = PhysicsRuntime(scene)
        self.geometry = BalanceKinematics(make_spec(self.rt.model))
        self.case = dict(id="stand", family="stand", split="train", keyframe="home", motion="stand", friction=1.)
        frames = []
        episode, _ = self.rt.rollout(self.case, 77, "position", .4,
            trace_callback=lambda rt, i, action, goal: frames.append(capture_frame(rt)))
        frames.append(capture_frame(self.rt))
        arrays = {key: np.stack([f[key] for f in frames]) for key in frames[0]}
        arrays.update(source_setpoint=np.asarray([s["applied_action"] for s in episode["steps"]]),
            observation=np.asarray([s["observation"] for s in episode["steps"]]))
        self.ref = FullBodyReference(arrays, layout_for(self.rt))
        self.references = [(dict(id="stand", sha256="fixture", case=self.case, source_family="stand"), self.ref)]
        self.schedule = ReferenceSchedule(self.references, self.geometry, [0])
        self.actor = ReferenceActor(338, 29, *self.rt.model.actuator_ctrlrange.T, torch.zeros(4, 5), [4, 5, 10, 11],
            history_length=3, future_length=2, width=16, latent_dim=8)
        phases = torch.tensor([0, 3]); clips = torch.zeros(2, dtype=torch.long)
        current, future, valid = self.schedule.command(clips, phases, 2)
        features = self.schedule.features(clips, torch.zeros_like(phases), phases)
        obs = torch.tensor(arrays["observation"], dtype=torch.float32)
        self.batch = dict(state=torch.tensor(arrays["state"][[0, 3]], dtype=torch.float32),
            history=obs[(phases[:, None]-torch.arange(2, -1, -1)[None]).clamp_min(0)],
            current=current, future=future, valid=valid, actual_features=features, reference_features=features,
            clip=clips, step=phases, origin=torch.zeros_like(phases), remaining=20-phases, context=torch.ones(2, 2))

    def test_imagination_has_finite_actor_gradients_through_frozen_model_and_memory(self):
        stats = {"state_mean": torch.zeros(71), "state_scale": torch.ones(71),
            "action_mean": torch.zeros(29), "action_scale": torch.ones(29),
            "context_mean": torch.zeros(2), "context_scale": torch.ones(2)}
        model = ResidualDynamics(stats, 16, True)
        with torch.no_grad(): model.net[-1].weight.normal_(0, .0001)
        value = ReferenceValue(self.actor, torch.zeros(71), torch.ones(71), 1)
        with torch.no_grad(): value.net[-1].weight.normal_(0, .002)
        for module in [model, value]:
            for p in module.parameters(): p.requires_grad_(False)
        before = {key: v.clone() for key, v in model.state_dict().items()}
        objective, active = imagined_objective(model, self.actor, value, self.batch, self.geometry, self.schedule,
            dict(imagination_horizon=4, gamma=.99))
        (-objective).backward()
        self.assertEqual(active, 8)
        self.assertTrue(all(torch.isfinite(p.grad).all() for p in self.actor.parameters() if p.grad is not None))
        self.assertGreater(float(self.actor.decoder[-1].weight.grad.abs().sum()), 0)
        self.assertTrue(all(p.grad is None for p in model.parameters()))
        self.assertTrue(all(torch.equal(v, model.state_dict()[key]) for key, v in before.items()))

    def test_policy_input_stop_preserves_forward_and_plant_gradient_but_blocks_feature_edge(self):
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        torch.manual_seed(1123)
        model = ResidualDynamics(stats, 16, True)
        with torch.no_grad():
            model.net[-1].weight.normal_(0, .0001)
            self.actor.decoder[-1].weight.normal_(0, .01)
            self.actor.feedback_coefficients.fill_(.02)
        for p in model.parameters(): p.requires_grad_(False)
        results = {}
        for route in ["full", "stop-policy-inputs"]:
            batch = dict(self.batch)
            batch["state"] = batch["state"].clone().requires_grad_(True)
            batch["actual_features"] = batch["actual_features"].clone().requires_grad_(True)
            value, active = imagined_objective(model, self.actor, None, batch, self.geometry, self.schedule,
                dict(imagination_horizon=4, gamma=.99, actor_critic_tail=False, actor_feedback_gradient=route))
            feature_grad, plant_grad, parameter_grad = torch.autograd.grad(value,
                (batch["actual_features"], batch["state"], self.actor.decoder[-1].bias), allow_unused=True)
            self.assertGreater(float(plant_grad.abs().sum()), 0.)
            self.assertGreater(float(parameter_grad.abs().sum()), 0.)
            results[route] = value.detach(), active, feature_grad, parameter_grad
        self.assertTrue(torch.equal(results["full"][0], results["stop-policy-inputs"][0]))
        self.assertEqual(results["full"][1], results["stop-policy-inputs"][1])
        self.assertGreater(float(results["full"][2].abs().sum()), 0.)
        self.assertIsNone(results["stop-policy-inputs"][2])
        self.assertFalse(torch.equal(results["full"][3], results["stop-policy-inputs"][3]))

    def test_behavior_loader_reconstructs_a_parameter_probe_from_its_frozen_base(self):
        from torch.nn.utils import parameters_to_vector
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            checkpoint = folder/"actor.pt"
            save_reference_actor(checkpoint, self.actor, self.geometry.spec, .02, {})
            checksum = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
            base = parameters_to_vector(self.actor.parameters()).detach()
            direction = torch.linspace(-1., 1., len(base))
            path = folder/"direction.pt"
            torch.save(dict(direction=direction, base_actor_sha256=checksum,
                parameter_names=[n for n, _ in self.actor.named_parameters()]), path)
            behavior = dict(checkpoint="actor.pt", sha256=checksum, direction_file="direction.pt",
                direction_sha256=hashlib.sha256(path.read_bytes()).hexdigest(), coefficient=.002)
            restored = load_behavior_actor(folder, behavior)
            torch.testing.assert_close(parameters_to_vector(restored.parameters()), base+.002*direction, atol=0, rtol=0)
            torch.testing.assert_close(parameters_to_vector(self.actor.parameters()), base, atol=0, rtol=0)

    def test_finite_gae_does_not_bootstrap_across_reference_end(self):
        batch = {key: torch.cat((value, value[:1]), 0) for key, value in self.batch.items()}
        batch.update(reward=torch.tensor([1., 2., 3.]), done=torch.tensor([False, True, True]))
        advantage = ppo_advantages(ZeroValue(), batch, self.schedule, dict(gamma=.5, gae_lambda=1.))
        expected = torch.tensor([2., 2., 3.])
        torch.testing.assert_close(advantage, expected/expected.std(unbiased=False))
        torch.testing.assert_close(finite_returns(torch.tensor([1., 2.]), .5), torch.tensor([2., 2.]))

    def test_prefix_only_removes_tail_without_extending_the_finite_reference(self):
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 16, True)
        class ConstantValue(torch.nn.Module):
            def forward(self, state, *args): return state[:, 0]*0+2
        class UnusedValue(torch.nn.Module):
            def forward(self, *args): raise AssertionError("prefix actor evaluated its critic")
        for h in [4, 20]:
            args = (self.batch, self.geometry, self.schedule, dict(imagination_horizon=h, gamma=.99))
            prefix, prefix_steps = imagined_objective(model, self.actor, PrefixOnlyValue(), *args)
            no_tail, no_tail_steps = imagined_objective(model, self.actor, UnusedValue(),
                self.batch, self.geometry, self.schedule, dict(imagination_horizon=h, gamma=.99, actor_critic_tail=False))
            torch.testing.assert_close(no_tail, prefix)
            self.assertEqual(no_tail_steps, prefix_steps)
            full, full_steps = imagined_objective(model, self.actor, ConstantValue(), *args)
            self.assertEqual(prefix_steps, full_steps)
            expected = 2*.99**h if h==4 else 0
            torch.testing.assert_close(full-prefix, torch.tensor(expected, dtype=full.dtype), atol=1e-6, rtol=1e-6)

    def test_actual_actor_updates_respect_the_calibrated_step_bound(self):
        torch.manual_seed(24)
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 16, True)
        with torch.no_grad(): model.net[-1].weight.normal_(0, .0001)
        for p in model.parameters(): p.requires_grad_(False); p.grad = None
        batch = {**self.batch, "episode_lengths": [1, 1]}
        initial = self.actor.decoder[-1].weight.detach().clone()
        result = optimize_model_actor(model, self.actor, PrefixOnlyValue(),
            torch.optim.Adam(self.actor.parameters(), lr=.01), batch, self.geometry, self.schedule,
            dict(imagination_horizon=4, gamma=.99, actor_critic_tail=False, maximum_actor_steps_per_cycle=2,
                actor_batch_size=2, actor_calibration_batch_size=4, actor_logit_rms_cap=.0001),
            torch.Generator().manual_seed(25))
        self.assertEqual(result["actor_steps"], 2)
        self.assertFalse(result["critic_tail_used"])
        self.assertFalse(torch.equal(initial, self.actor.decoder[-1].weight))
        self.assertTrue(all(0 < row["applied_logit_rms"] <= .0001 for row in result["logit_step_calibration"]))
        self.assertTrue(all(p.grad is None for p in model.parameters()))

    def test_model_windows_do_not_cross_resets_and_collection_records_actual_actions(self):
        episodes = []
        for offset in [0., 100.]:
            states = (torch.arange(6)+offset)[:, None].expand(-1, 71)
            episodes.append(dict(state=states, next_state=states+1, action=torch.zeros(6, 29), context=torch.ones(6, 2)))
        replay = ReferenceModelReplay(join_batches(episodes), dict(model_window=4, model_replay_windows=20,
            model_normalization_floor=.05, model_width=8, model_learning_rate=.001), 0)
        torch.testing.assert_close(replay.parts["state"][:, 0, 0], torch.tensor([0., 1., 2., 100., 101., 102.]))
        with tempfile.TemporaryDirectory() as directory:
            config = dict(noise_seed_base=10, raw_action_std=.03, maximum_action_alignment_error_rad=8e-5,
                maximum_feature_alignment_error=2e-5, gamma=.99)
            batch, record, trial = collect_episode(self.rt, self.references, self.schedule, self.actor, self.geometry,
                config, 0, 0, 0, 0, "training", Path(directory), dict(checkpoint="fixture"))
            self.assertEqual(record["steps"], len(batch["state"]))
            self.assertLess(record["maximum_action_alignment_error"], 8e-5)
            self.assertEqual(float(batch["done"].sum()), 1)
            self.assertEqual(len(batch["reward"]), trial["steps"])
            restored = restore_collected_batch(Path(directory), record, self.actor, self.schedule, config)
            self.assertEqual(batch.keys(), restored.keys())
            for key in batch: torch.testing.assert_close(restored[key], batch[key], atol=0, rtol=0)
            offset = 3
            middle = take(restored, torch.tensor([offset]))
            self.assertEqual(int(middle["origin"][0]), 0)
            self.assertEqual(int(middle["step"][0]), offset)
            torch.testing.assert_close(middle["history"][0, -1], restored["history"][offset, -1], atol=0, rtol=0)
            stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
                for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
            model = ResidualDynamics(stats, 8, True)
            result, active = imagined_objective(model, self.actor, PrefixOnlyValue(), middle, self.geometry,
                self.schedule, dict(imagination_horizon=self.ref.steps+2, gamma=.99, actor_critic_tail=False))
            self.assertTrue(torch.isfinite(result))
            self.assertEqual(active, self.ref.steps-offset)

    def test_actor_origin_modes_cover_only_the_intended_physical_states(self):
        batch = dict(state=torch.zeros(8, 71), episode_lengths=[3, 5])
        reset = actor_origin_indices(batch, dict(actor_batch_size=1024), torch.Generator().manual_seed(9))
        self.assertEqual(set(reset.tolist()), {0, 3})
        trajectory = actor_origin_indices(batch, dict(actor_batch_size=1024, actor_origin_sampling="trajectory-states"),
            torch.Generator().manual_seed(9))
        self.assertEqual(set(trajectory.tolist()), set(range(8)))

    def test_extension_reuses_only_shared_and_selected_baseline_evidence(self):
        report = dict(physical_records=[dict(episode_id=name, role=role) for name, role in [
            ("initial", "initial"), ("common", "common-first-collection"), ("diagnostic", "model-diagnostic"),
            ("trajectory-train", "training"), ("trajectory-final", "final"),
            ("reset-train", "training"), ("reset-final", "final")]], runs=[
            dict(method="replay-prefix", cycles=[dict(training_episode_ids=["common", "trajectory-train"])],
                trials=[dict(episode_id="trajectory-final")]),
            dict(method="prefix-only", cycles=[dict(training_episode_ids=["common", "reset-train"])],
                trials=[dict(episode_id="reset-final")])])
        self.assertEqual(baseline_record_ids(report, "replay-prefix"),
            {"initial", "common", "diagnostic", "trajectory-train", "trajectory-final"})

    def test_extension_reconstruction_checks_actor_model_and_value_tensors(self):
        stats = {name+suffix: value for name, n in [("state", 71), ("action", 29), ("context", 2)]
            for suffix, value in [("_mean", torch.zeros(n)), ("_scale", torch.ones(n))]}
        model = ResidualDynamics(stats, 8, True)
        value = ReferenceValue(self.actor, torch.zeros(71), torch.ones(71), 1)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); actor_path = folder/"actor-cycle-1.pt"
            save_reference_actor(actor_path, self.actor, self.geometry.spec, .02, dict(fixture=True))
            torch.save(dict(model=model.state_dict()), folder/"dynamics-cycle-1.pt")
            torch.save(dict(state_dict=value.state_dict()), folder/"value-cycle-1.pt")
            cycle = dict(cycle=1, checkpoint=dict(checkpoint=str(actor_path), sha256=hashlib.sha256(actor_path.read_bytes()).hexdigest()))
            self.assertTrue(verify_reconstructed_cycle(self.actor, model, value, cycle, folder)["all_tensors_identical"])
            with torch.no_grad(): model.net[-1].bias[0] += .001
            with self.assertRaisesRegex(ValueError, "model differs"):
                verify_reconstructed_cycle(self.actor, model, value, cycle, folder)

    def test_initial_anchor_keeps_first_three_fits_then_replaces_only_recent_capacity(self):
        def episode(offset):
            state = (torch.arange(6, dtype=torch.float32)+offset)[:, None].expand(-1, 71).clone()
            state[:, 3:7] = torch.tensor([1., 0., 0., 0.])
            target = state.clone(); target[:, 42:] += .01
            return join_batches([dict(state=state, next_state=target, action=torch.zeros(6, 29), context=torch.ones(6, 2))])
        config = dict(model_window=4, model_replay_windows=9, model_normalization_floor=.05,
            model_width=8, model_learning_rate=.001, model_updates_per_cycle=2, model_batch_size=4)
        torch.manual_seed(86); fifo = ReferenceModelReplay(episode(0), config, 1)
        torch.manual_seed(86); anchor = ReferenceModelReplay(episode(0), {**config, "model_initial_anchor_after_cycle": 3}, 1)
        for cycle in range(3):
            if cycle:
                fifo.append(episode(cycle*100)); anchor.append(episode(cycle*100))
            self.assertEqual(fifo.fit()["sample_indices_sha256"], anchor.fit()["sample_indices_sha256"])
            self.assertEqual(state_digest(fifo.model), state_digest(anchor.model))
        fifo.append(episode(300)); anchor.append(episode(300))
        torch.testing.assert_close(fifo.parts["state"][:, 0, 0], torch.tensor([100., 101., 102., 200., 201., 202., 300., 301., 302.]))
        torch.testing.assert_close(anchor.parts["state"][:, 0, 0], torch.tensor([0., 1., 2., 200., 201., 202., 300., 301., 302.]))
        self.assertEqual(anchor.anchor_windows, 3)
        # Every retained window stays within its original episode.
        torch.testing.assert_close(anchor.parts["state"][:, -1, 0]-anchor.parts["state"][:, 0, 0], torch.full((9,), 3.))
        generator = torch.Generator(); generator.set_state(anchor.generator.get_state())
        expected = [torch.randint(9, (4,), generator=generator) for _ in range(2)]
        digest = hashlib.sha256()
        for ids in expected: digest.update(ids.numpy().tobytes())
        fit = anchor.fit()
        self.assertEqual(fit["sample_indices_sha256"], digest.hexdigest())
        self.assertEqual(fit["anchor_samples"], sum(int((ids<3).sum()) for ids in expected))
        self.assertEqual(fit["recent_windows"], 6)


if __name__ == "__main__":
    unittest.main()
