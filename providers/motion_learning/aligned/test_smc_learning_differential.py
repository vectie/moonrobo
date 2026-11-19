"""Numerical comparisons against executed ../smc source, without launching Isaac.

Imports use a private package. Only type-only kinematics/motion dependencies are
stubbed; upstream rotations/MDP/networks/buffer and train function bodies execute
unchanged. Train function AST selection avoids top-level argument parsing/GPU
startup, while keeping the reference equations/optimizer operations authoritative.
"""
from __future__ import annotations

import ast
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

import torch

from .buffer import ReplayBuffer
from .learning import AlignedLearner
from .networks import Critic, Policy, WorldModel
from .test_aligned_learning import FixtureMDP, transition


SMC = Path(__file__).resolve().parents[4] / "smc" / "supermimic"


def reference_modules():
    package = "_moonrobo_smc_numerical"
    if package + ".networks" in sys.modules:
        return {name: sys.modules[package + "." + name] for name in ("rotations", "mdp", "networks", "buffer")}
    root = types.ModuleType(package)
    root.__path__ = [str(SMC)]
    sys.modules[package] = root
    kin = types.ModuleType(package + ".kinematics")
    kin.G1Kinematics = object
    motion = types.ModuleType(package + ".motion")
    motion.MotionLib, motion.CONTROL_DT = object, 0.02
    sys.modules[kin.__name__], sys.modules[motion.__name__] = kin, motion
    loaded = {}
    for name in ("rotations", "mdp", "networks", "buffer"):
        spec = importlib.util.spec_from_file_location(package + "." + name, SMC / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        loaded[name] = module
    return loaded


def reference_train(context):
    tree = ast.parse((SMC / "train.py").read_text())
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(SMC / "train.py"), "exec"), context)
    context.update(wm_rollout=context["_wm_rollout"], wm_err=context["_wm_err"],
                   imag_step=context["_imag_step"], reward_term=context["_reward_term"],
                   critic_input_c=context["_critic_input"])
    return context


def assert_state_close(test, left, right, *, atol=0, rtol=0):
    if isinstance(left, dict):
        test.assertEqual(left.keys(), right.keys())
        for key in left:
            assert_state_close(test, left[key], right[key], atol=atol, rtol=rtol)
    elif isinstance(left, (tuple, list)):
        test.assertEqual(len(left), len(right))
        for a, b in zip(left, right):
            assert_state_close(test, a, b, atol=atol, rtol=rtol)
    elif isinstance(left, torch.Tensor):
        torch.testing.assert_close(left, right, atol=atol, rtol=rtol)
    else:
        test.assertEqual(left, right)


@unittest.skipUnless((SMC / "train.py").exists(), "local ../smc reference checkout unavailable")
class SmcLearningDifferentialTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ref = reference_modules()
        torch.set_num_threads(1)

    def setUp(self):
        torch.manual_seed(912)

    def learner_and_reference(self):
        config = dict(wm_hidden=(16, 16, 16), pi_hidden=(16, 12), critic_hidden=(16, 8),
                      wm_batch=2, wm_batches=1, pi_batch=2, critic_epochs=2,
                      critic_minibatches=4, observation_noise=False)
        learner = AlignedLearner(FixtureMDP(), config)
        refnet = self.ref["networks"]
        wm = refnet.WorldModel(hidden=config["wm_hidden"])
        original_mlp = refnet.mlp
        # The upstream constructors fix policy/critic widths. Execute their
        # original forward paths at explicit small test widths to bound memory.
        with patch.object(refnet, "mlp", side_effect=lambda inp, hidden, out, **kw:
                          original_mlp(inp, list(config["pi_hidden"]), out, **kw)):
            pi = refnet.Policy(FixtureMDP.obs_dim, 730)
        with patch.object(refnet, "mlp", side_effect=lambda inp, hidden, out, **kw:
                          original_mlp(inp, list(config["critic_hidden"]), out, **kw)):
            critic = refnet.Critic(learner.critic.norm.mean.numel())
        for a, b in ((learner.wm, wm), (learner.pi, pi), (learner.critic, critic)):
            b.load_state_dict(a.state_dict())
        args = types.SimpleNamespace(**{**learner.config, "no_critic": False})
        context = reference_train(dict(torch=torch, nn=torch.nn, args=args, wm=wm, pi=pi,
            critic=critic, opt_wm=torch.optim.Adam(wm.parameters(), lr=args.lr),
            opt_pi=torch.optim.Adam(pi.parameters(), lr=args.lr, betas=(0.9, .95)),
            opt_v=torch.optim.Adam(critic.parameters(), lr=args.lr), mdp=learner.mdp,
            motion=learner.motion, K=10, Hh=10, HZ=32, dev="cpu", PROFILE=False,
            ERR_FLOOR=learner.error_floor, normalize_xi=self.ref["mdp"].normalize_xi,
            unflatten_state=self.ref["mdp"].unflatten_state))
        return learner, context

    def test_default_architecture_parameter_shapes_match_upstream(self):
        with torch.device("meta"):
            for ours, theirs in ((WorldModel(), self.ref["networks"].WorldModel()),
                                (Policy(99, 730), self.ref["networks"].Policy(99, 730)),
                                (Critic(914), self.ref["networks"].Critic(914))):
                self.assertEqual({k: tuple(v.shape) for k, v in ours.state_dict().items()},
                                 {k: tuple(v.shape) for k, v in theirs.state_dict().items()})

    def test_network_outputs_and_world_model_8step_adam_match(self):
        ours, upstream = self.learner_and_reference()
        b = ReplayBuffer(16, 1)
        for i in range(16):
            tr = transition(i)
            b.add(tr)
            ours.observe(tr)
        upstream["wm"].load_state_dict(ours.wm.state_dict())
        w = b.sample_windows(2, 8)
        fixed = types.SimpleNamespace(sample_windows=lambda *args: w, can_sample_windows=lambda k: True)
        upstream["buffer"] = fixed
        # Nonzero learned outputs exercise local rotations/increments, not only
        # the zero-initialized identity network.
        with torch.no_grad():
            ours.wm.net[-1].weight.normal_(std=.01)
        upstream["wm"].load_state_dict(ours.wm.state_dict())
        S = self.ref["mdp"].unflatten_state(w["s"][:, 0])
        action, xi = w["a"][:, 0], self.ref["mdp"].normalize_xi(w["xi"][:, 0])
        assert_state_close(self, ours.wm.step(S, action, xi), upstream["wm"].step(S, action, xi))
        obs, goals = torch.randn(2, 10, 93), torch.randn(2, 730)
        assert_state_close(self, ours.pi(obs, goals), upstream["pi"](obs, goals), atol=0, rtol=0)
        x = torch.randn(2, ours.critic.norm.mean.numel())
        assert_state_close(self, ours.critic(x), upstream["critic"](x), atol=0, rtol=0)
        ref_loss, ref_last = upstream["wm_update"]()
        result = ours.fit_world_model(fixed)
        self.assertAlmostEqual(result["wm_loss"], float(ref_loss), places=7)
        self.assertAlmostEqual(result["wm_err8"], float(ref_last), places=7)
        assert_state_close(self, ours.wm.state_dict(), upstream["wm"].state_dict())
        assert_state_close(self, ours.opt_wm.state_dict(), upstream["opt_wm"].state_dict())
        for a, b in zip(ours.wm.parameters(), upstream["wm"].parameters()):
            assert_state_close(self, a.grad, b.grad)

    def test_32step_actor_and_gae_critic_updates_match_actual_smc_function(self):
        ours, upstream = self.learner_and_reference()
        with torch.no_grad():
            ours.wm.net[-1].weight.normal_(std=0.001)
        upstream["wm"].load_state_dict(ours.wm.state_dict())
        b = ReplayBuffer(16, 1)
        for i in range(16):
            b.add(transition(i))
        start, history = b.sample_starts(2, 10, motion=ours.motion, horizon=32)
        fixed = types.SimpleNamespace(sample_starts=lambda *args, **kwargs: (start, history))
        upstream["sample_valid_starts"] = lambda B: (start, history)
        # Match original constructor states and every critic shuffle RNG draw.
        rng = torch.get_rng_state()
        expected = upstream["policy_update"]()
        torch.set_rng_state(rng)
        actual = ours.update_policy(fixed)
        self.assertAlmostEqual(actual["pi_loss"], float(expected[0]), places=6)
        self.assertAlmostEqual(actual["imag_rew"], float(expected[2]), places=6)
        self.assertAlmostEqual(actual["pi_gradnorm"], float(expected[3]), places=6)
        self.assertAlmostEqual(actual["imag_survival"], float(expected[4]), places=6)
        for name in ("pi", "wm", "critic", "opt_pi", "opt_v"):
            assert_state_close(self, getattr(ours, name).state_dict(), upstream[name].state_dict())

    def test_replay_same_windows_history_and_exact_ring_restore(self):
        ours, theirs = ReplayBuffer(8, 1), self.ref["buffer"].ReplayBuffer(8, 1, "cpu")
        for i in range(15):
            tr = transition(i if i < 10 else i + 20, i if i < 10 else i - 10, done=i == 9)
            ours.add(tr)
            theirs.add(tr)
        rng = torch.get_rng_state()
        ow = ours.sample_windows(4, 8)
        torch.set_rng_state(rng)
        tw = theirs.sample_windows(4, 8)
        for key in tw:
            assert_state_close(self, ow[key], tw[key], atol=0, rtol=0)
        ages = torch.tensor([0, 2, 3, 7])
        with patch("torch.randint", side_effect=[ages, torch.zeros_like(ages)]):
            ts, th = theirs.sample_starts(4, 10)
        with patch("torch.randint", side_effect=[ages]):
            os, oh = ours.sample_starts(4, 10)
        assert_state_close(self, (os, oh), (ts, th), atol=0, rtol=0)
        restored = ReplayBuffer(8, 1)
        restored.load_state_dict(ours.state_dict())
        rng = torch.get_rng_state()
        before = ours.sample_starts(20, 10)
        torch.set_rng_state(rng)
        after = restored.sample_starts(20, 10)
        assert_state_close(self, before, after, atol=0, rtol=0)


def export_float32_qualification(directory):
    """Export actual upstream executions; orchestration stays in MoonBit.

    The preserved train function bodies, networks and real Adam optimizers run
    unchanged. Hooks observe clipping/steps and supply fixed exogenous samples;
    they never replace a reference result with a candidate computation.
    """
    import hashlib
    import json
    import numpy as np

    output = Path(directory).resolve()
    output.mkdir(parents=True, exist_ok=False)
    source_root = SMC.parents[1]
    repo = Path(__file__).resolve().parents[3]
    SmcLearningDifferentialTests.setUpClass()
    methods = {
        "learning.world8": "test_network_outputs_and_world_model_8step_adam_match",
        "learning.policy32": "test_32step_actor_and_gae_critic_updates_match_actual_smc_function",
    }
    def identity(path):
        path = path.resolve()
        return dict(path=str(path.relative_to(source_root)), sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    upstream_paths = [SMC / (name + ".py") for name in ("networks", "rotations", "mdp", "train")]
    upstream_paths += [Path(__file__), Path(__file__).with_name("test_aligned_learning.py"),
                       Path(__file__).with_name("buffer.py"), Path(__file__).with_name("mdp.py"),
                       Path(__file__).with_name("rotations.py")]
    upstream_paths = sorted(set(upstream_paths + list(Path(__file__).parent.glob("*.py"))))
    native_paths = sorted((repo / "src/learning_aligned_gpu").rglob("*.mbt"))
    native_paths += sorted((repo / "src/learning_tensor").glob("*.mbt"))
    native_paths += sorted((repo / "src/learning_tensor").glob("*.inc"))
    native_paths += sorted((repo / "src/learning_tensor").glob("*.c"))
    native_paths += sorted((repo / "src/learning_artifacts").glob("*.mbt"))
    native_paths += [repo / "src/learning_tensor/adapter.cpp",
                     repo / "scripts/qualify_upstream_float32.mbtx",
                     repo / "qualification/upstream_float32/native_driver.mbt.in"]
    cases = []
    for case_id, method in methods.items():
        case = SmcLearningDifferentialTests(method)
        case.ref = SmcLearningDifferentialTests.ref
        case.setUp()
        ours, ctx = case.learner_and_reference()
        inputs, expected = {}, {}
        def put(target, name, value):
            if isinstance(value, torch.Tensor):
                value = value.detach().cpu().numpy().copy()
            else:
                value = np.asarray(value, dtype=np.float64)
            target[name] = value
        def capture_models(prefix):
            for model in ("wm", "pi", "critic"):
                for name, value in ctx[model].state_dict().items():
                    put(expected if prefix == "weights_after." else inputs, prefix + model + "." + name, value)
        for name, value in dict(hist=10, goal_frames=10, horizon=32, wm_window=8,
                                wm_batch=2, pi_batch=2, critic_epochs=2,
                                critic_minibatches=4, lr=.0002, gamma=.99, lam=.95,
                                no_critic=0, observation_noise=0).items():
            put(inputs, "config." + name, value)
        replay = ReplayBuffer(16, 1)
        for i in range(16):
            row = transition(i)
            replay.add(row)
            if case_id == "learning.world8":
                ours.observe(row)
        with torch.no_grad():
            ours.wm.net[-1].weight.normal_(std=.01 if case_id == "learning.world8" else .001)
        ctx["wm"].load_state_dict(ours.wm.state_dict())
        if case_id == "learning.world8":
            windows = replay.sample_windows(2, 8)
            ctx["buffer"] = types.SimpleNamespace(sample_windows=lambda *args: windows)
            for key in ("s", "s1", "a", "xi", "mask"):
                put(inputs, "inputs.windows." + key, windows[key])
            put(inputs, "inputs.error_floor", ours.error_floor)
            state = windows["s"][:, 0]
            action = windows["a"][:, 0]
            xi = ctx["normalize_xi"](windows["xi"][:, 0])
            history, goal = torch.randn(2, 10, 93), torch.randn(2, 730)
            features = torch.randn(2, ours.critic.norm.mean.numel())
            for name, value in dict(state=state, action=action, xi_normalized=xi,
                                    observation_history=history, goal=goal,
                                    critic_features=features).items():
                put(inputs, "inputs." + name, value)
            result = ctx["wm"].step(ctx["unflatten_state"](state), action, xi)
            for name, value in zip(("p", "R", "v", "w", "q", "qd"), result):
                put(expected, "network.world." + name, value)
            put(expected, "network.policy", ctx["pi"](history, goal))
            put(expected, "network.critic", ctx["critic"](features))
        else:
            starts, history = replay.sample_starts(2, 10, motion=ours.motion, horizon=32)
            ctx["sample_valid_starts"] = lambda count: (starts, history)
            for prefix, values in (("inputs.starts.", starts), ("inputs.history.", history)):
                for name in ("s", "a_prev", "xi", "f"):
                    put(inputs, prefix + name, values[name])
        capture_models("weights.")
        for model in ("wm", "pi", "critic"):
            for name, parameter in ctx[model].named_parameters():
                for moment in ("exp_avg", "exp_avg_sq"):
                    put(inputs, "optimizer_before." + model + "." + name + "." + moment, torch.zeros_like(parameter))
                put(inputs, "optimizer_before." + model + "." + name + ".step", torch.zeros(()))
        before = torch.get_rng_state().clone()
        put(inputs, "rng.before", before)
        steps, orders = {"wm": 0, "pi": 0, "critic": 0}, []
        active = ("wm",) if case_id == "learning.world8" else ("pi", "critic")
        parameter_models = {id(p): model for model in active for p in ctx[model].parameters()}
        clip = torch.nn.utils.clip_grad_norm_
        permute = torch.randperm
        def gradient_key(model, name, kind):
            stage = "step" + str(steps[model]) + "." if model == "critic" else ""
            return "grad." + kind + "." + model + "." + stage + name
        def observe_clip(parameters, *args, **kwargs):
            parameters = list(parameters)
            model = parameter_models[id(parameters[0])]
            for name, p in ctx[model].named_parameters():
                put(expected, gradient_key(model, name, "raw"), p.grad)
            return clip(parameters, *args, **kwargs)
        def observe_permutation(*args, **kwargs):
            value = permute(*args, **kwargs)
            orders.append(value.clone())
            return value
        for model, optimizer_key in (("wm", "opt_wm"), ("pi", "opt_pi"), ("critic", "opt_v")):
            if model not in active:
                continue
            optimizer = ctx[optimizer_key]
            original_step = optimizer.step
            def step(*args, _model=model, _optimizer=optimizer, _original=original_step, **kwargs):
                for name, p in ctx[_model].named_parameters():
                    put(expected, gradient_key(_model, name, "clipped"), p.grad)
                result = _original(*args, **kwargs)
                steps[_model] += 1
                return result
            optimizer.step = step
        with patch.object(torch.nn.utils, "clip_grad_norm_", observe_clip), patch.object(torch, "randperm", observe_permutation):
            if case_id == "learning.world8":
                loss, last = ctx["wm_update"]()
                put(expected, "metrics.wm_loss", loss)
                put(expected, "metrics.wm_err8", last)
            else:
                loss, _, reward, norm, survival = ctx["policy_update"]()
                for name, value in dict(pi_loss=loss, imag_rew=reward, pi_gradnorm=norm, imag_survival=survival).items():
                    put(expected, "metrics." + name, value)
        after = torch.get_rng_state().clone()
        put(expected, "rng.after", after)
        if orders:
            put(inputs, "inputs.critic_permutations", torch.stack(orders))
            put(inputs, "rng.calls", torch.tensor([[2, 64, 0], [2, 64, 0]], dtype=torch.int64))
        else:
            put(inputs, "rng.calls", torch.empty(0, 3, dtype=torch.int64))
        models = ("wm",) if case_id == "learning.world8" else ("wm", "pi", "critic")
        for model in models:
            for name, value in ctx[model].state_dict().items():
                put(expected, "weights_after." + model + "." + name, value)
        for model, key in (("wm", "opt_wm"), ("pi", "opt_pi"), ("critic", "opt_v")):
            if model not in active:
                continue
            for name, p in ctx[model].named_parameters():
                for kind, value in ctx[key].state[p].items():
                    put(expected, "optimizer_after." + model + "." + name + "." + kind, value)
        folder = output / case_id
        folder.mkdir()
        np.savez(folder / "input.npz", **inputs)
        np.savez(folder / "expected.npz", **expected)
        manifest = dict(format="moonrobo.smc-differential.fixture.v1", case_id=case_id,
            oracle_kind="executed-upstream-python", upstream_revision="a1508d42c9d1699a52e8233ab16d08c488441ab9",
            upstream_sources={str(p.relative_to(source_root)): identity(p) for p in upstream_paths},
            candidate_sources={str(p.relative_to(source_root)): identity(p) for p in native_paths},
            original_test=identity(Path(__file__)), producer=identity(Path(__file__)),
            torch_version=torch.__version__, device="cpu", threads=1, dtype="float32",
            config={"original_method": "SmcLearningDifferentialTests." + method},
            input=dict(path="input.npz", sha256=hashlib.sha256((folder / "input.npz").read_bytes()).hexdigest()),
            expected=dict(path="expected.npz", sha256=hashlib.sha256((folder / "expected.npz").read_bytes()).hexdigest()),
            rng_before_sha256=hashlib.sha256(before.numpy().tobytes()).hexdigest(),
            rng_after_sha256=hashlib.sha256(after.numpy().tobytes()).hexdigest(),
            input_keys=sorted(inputs), expected_keys=sorted(expected))
        encoded = json.dumps(manifest, sort_keys=True, indent=2) + "\n"
        (folder / "fixture.json").write_text(encoded)
        cases.append(dict(case_id=case_id, folder=case_id, manifest_sha256=hashlib.sha256(encoded.encode()).hexdigest()))
    (output / "suite.json").write_text(json.dumps(dict(format="moonrobo.strict-float32.suite.v1",
        source_root=str(source_root), cases=cases), indent=2) + "\n")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--export-float32":
        export_float32_qualification(sys.argv[2])
    else:
        unittest.main()
