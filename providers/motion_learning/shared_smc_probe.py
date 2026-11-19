"""SMC numerical adapter for the MoonBit-owned paired measurement protocol.

No deployment, subprocesses, dataset downloads or experiment orchestration live
here. Import the pinned SMC implementation; extract its training functions without
importing Isaac's launcher. The synthetic tensors/parameters are read from the
MoonBit fixture, not regenerated from a nominally equal seed.
"""
import ast
import contextlib
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace, ModuleType, MethodType

import numpy as np
import torch
from torch import nn

# Read the original robot constants/functions without importing Isaac startup
# configuration. Physics is deliberately outside this fixed-compute fixture.
robot_path = Path(os.environ["SHARED_SMC_TRAIN"]).with_name("robot.py")
robot_nodes = []
for node in ast.parse(robot_path.read_text()).body:
    if isinstance(node, ast.Import) and any(n.name.startswith("isaaclab") for n in node.names):
        continue
    if isinstance(node, ast.ImportFrom) and (node.module or "").startswith("isaaclab"):
        continue
    if isinstance(node, ast.FunctionDef) and node.name == "_actuators":
        continue
    if isinstance(node, ast.Assign) and any(isinstance(n, ast.Name) and n.id == "G1_CFG" for n in node.targets):
        continue
    robot_nodes.append(node)
robot_module = ModuleType("supermimic.robot")
robot_module.__file__ = str(robot_path)
exec(compile(ast.Module(body=robot_nodes, type_ignores=[]), str(robot_path), "exec"), robot_module.__dict__)
sys.modules["supermimic.robot"] = robot_module

from supermimic import networks
from supermimic import mdp as mdp_module
from supermimic.kinematics import G1Kinematics
from supermimic.mdp import MDP, normalize_xi, unflatten_state
from supermimic.networks import WorldModel, Policy, Critic
from supermimic.robot import default_joint_pos_list
from supermimic.rotations import so3_log


class Meter:
    def __init__(self, mode, drain_backward=False):
        self.mode, self.spans = mode, []
        self.drain_backward = drain_backward
        self.capture_drained = False

    @contextlib.contextmanager
    def span(self, name):
        if self.mode == "off":
            yield
            return
        first = last = None
        if self.mode == "events":
            first, last = (torch.cuda.Event(enable_timing=True) for _ in range(2))
            first.record()
        if self.mode in ("ranges", "aten"):
            torch.cuda.nvtx.range_push(name)
        start = time.perf_counter_ns()
        try:
            yield
        finally:
            # Diagnostic capture only: do not close the stop-trigger range while
            # its kernels are pending. Never enabled for off/events or training.
            if self.drain_backward and not self.capture_drained and name == "diag.actor.backward":
                torch.cuda.synchronize()
                self.capture_drained = True
            cpu = (time.perf_counter_ns() - start) / 1e6
            if last is not None:
                last.record()
            if self.mode in ("ranges", "aten"):
                torch.cuda.nvtx.range_pop()
            assert len(self.spans) < 512
            self.spans.append((name, cpu, first, last))

    def report(self):
        return [{"label": name, "cpu_ms": cpu,
                 "stream_elapsed_ms": first.elapsed_time(last) if first else None}
                for name, cpu, first, last in self.spans]


def expanded_layer_norm(module, x):
    """Diagnostic inverse ablation: MoonBit Expanded expression, same weights."""
    centered = x - x.mean(-1, keepdim=True)
    return centered / (centered.square().mean(-1, keepdim=True) + module.eps).sqrt() * module.weight + module.bias


class SharedProbe:
    def __init__(self, root, compiled):
        self.root = Path(root)
        self.fixture = json.loads((self.root / "fixture.json").read_text())
        assert self.fixture["schema"] == "moonrobo.shared-compute-fixture.v1"
        self.initial = json.loads((self.root / "initial.json").read_text())
        self.records = {r["name"]: r["blob"] for r in self.fixture["records"] + self.initial["records"]}
        assert torch.cuda.mem_get_info()[0] > 64 * 1024**3
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True
        networks.AMP_DTYPE = None
        self.wm = WorldModel().cuda()
        self.layernorm_control = os.environ.get("SHARED_LAYERNORM_CONTROL", "original-native")
        assert self.layernorm_control in ("original-native", "expanded")
        if self.layernorm_control == "expanded":
            for module in self.wm.modules():
                if isinstance(module, nn.LayerNorm):
                    module.forward = MethodType(expanded_layer_norm, module)
        self.pi = Policy(99, 730, hist=10).cuda()
        self.critic = Critic(914).cuda()
        self.models = (self.wm, self.pi, self.critic)
        self.rotation_control = os.environ.get("SHARED_ROTATION_CONTROL", "original-acos")
        assert self.rotation_control in ("original-acos", "quaternion-log")
        if self.rotation_control == "quaternion-log":
            # Isolated causal numerical control only. Original mdp.py is retained.
            # This mirrors MoonBit angle_square's expression; it is never enabled
            # in the baseline or promoted as an execution-only optimization.
            mdp_module.rot_angle_sq = lambda a, b: so3_log(a @ b.transpose(-1, -2)).square().sum(-1)
        self.opts = (torch.optim.Adam(self.wm.parameters(), lr=2e-4),
                     torch.optim.Adam(self.pi.parameters(), lr=2e-4, betas=(.9, .95)),
                     torch.optim.Adam(self.critic.parameters(), lr=2e-4))
        self.frozen = {}
        for i, (name, model) in enumerate(zip(("world", "policy", "critic"), self.models)):
            for j, p in enumerate(model.parameters()):
                value = self.read(f"{name}-{j}-parameter")
                assert value.shape == p.shape
                self.frozen[f"{name}-{j}-parameter"] = value
                if self.initial["optimizer_metadata"][i]["states"][j]["present"]:
                    for k in (1, 2):
                        self.frozen[f"{name}-{j}-moment{k}"] = self.read(f"{name}-{j}-moment{k}")
        self.world = {k: self.read("world-" + k) for k in ("s", "s1", "actions", "xi", "mask")}
        self.state, self.xi, self.previous, self.history = (
            self.read(n) for n in ("state", "xi", "previous", "history"))
        self.trained = self.fixture.get("source_checkpoint") is not None
        if self.trained:
            self.goals = torch.cat([self.read(f"goal-{i}") for i in range(33)])
            self.noise = torch.cat([self.read(f"noise-{i}") for i in range(32)])
        else:
            self.goals = self.read("goal").repeat(33, 1)
            self.noise = self.read("noise").repeat(32, 1)
        self.orders = [self.read(f"order-{i}", torch.int64) for i in range(5)]
        self.reset()
        self.ctx = dict(torch=torch, nn=nn, wm=self.wm, pi=self.pi, critic=self.critic,
                        unflatten_state=unflatten_state, normalize_xi=normalize_xi,
                        args=SimpleNamespace(wm_window=8),
                        dev="cuda:0", HZ=32, Hh=10, K=10, PROFILE=False,
                        ERR_FLOOR=torch.tensor([.003]*3+[.005]*3+[.02]*3+[.05]*3+[.003]*29+[.05]*29, device="cuda"))
        # Retain the exact world-rollout/loss function AST from original train.py.
        source = Path(os.environ["SHARED_SMC_TRAIN"]).read_text()
        wanted = {"_wm_rollout", "_wm_err", "_imag_step", "_reward_term", "_critic_input", "set_requires_grad"}
        definitions = [n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name in wanted]
        assert {n.name for n in definitions} == wanted
        # Fixed exogenous noise/reference indexing replaces RNG/data selection,
        # not the network, integration, reward, GAE or optimizer equations.
        class FixedInputs(ast.NodeTransformer):
            def visit_FunctionDef(self, node):
                if node.name != "_imag_step":
                    return node
                return self.generic_visit(node)
            def visit_Assign(self, node):
                if len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                    if node.targets[0].id == "f1":
                        node.value = ast.parse("f + 4096", mode="eval").body
                    if node.targets[0].id == "o1":
                        node.value = ast.parse("mdp.obs(S1, a, xi, f1) + fixed_noise[f1 - 4096]", mode="eval").body
                return node
        module = ast.fix_missing_locations(FixedInputs().visit(ast.Module(body=definitions, type_ignores=[])))
        exec(compile(module, "pinned-smc-fixed-exogenous-inputs", "exec"), self.ctx)
        compile_fn = torch.compile if compiled else lambda f: f
        self.rollout, self.err = compile_fn(self.ctx["_wm_rollout"]), compile_fn(self.ctx["_wm_err"])
        self.compiled, self.actor_ready = compiled, False

    def read(self, name, dtype=torch.float32):
        blob = self.records[name]
        assert blob["dtype"] == "f64le" and 0 < int(blob["count"]) <= 16777216
        path = self.root / blob["file"]
        assert path.parent == self.root and path.stat().st_size == int(blob["byte_length"])
        with path.open("rb") as f:
            digest = hashlib.file_digest(f, "sha256").hexdigest()
        assert digest == blob["sha256"], name
        # Each tensor <=128MiB; mmap avoids an extra unbounded Python copy.
        a = np.memmap(path, mode="c", dtype="<f8", shape=tuple(blob["shape"]))
        return torch.from_numpy(a).to(device="cuda", dtype=dtype)

    @torch.no_grad()
    def reset(self):
        for i, (name, model, opt) in enumerate(zip(("world", "policy", "critic"), self.models, self.opts)):
            opt.zero_grad(set_to_none=True)
            opt.state.clear()
            group = self.initial["optimizer_metadata"][i]["groups"][0]
            opt.param_groups[0].update(lr=group["learning_rate"], betas=(group["beta1"], group["beta2"]),
                                       eps=group["eps"], weight_decay=group["weight_decay"], amsgrad=group["amsgrad"])
            for j, p in enumerate(model.parameters()):
                p.copy_(self.frozen[f"{name}-{j}-parameter"])
                info = self.initial["optimizer_metadata"][i]["states"][j]
                if info["present"]:
                    opt.state[p] = dict(step=torch.tensor(float(info["step"])),
                                       exp_avg=self.frozen[f"{name}-{j}-moment1"].clone(),
                                       exp_avg_sq=self.frozen[f"{name}-{j}-moment2"].clone())
        norms = (self.wm.in_norm, self.wm.out_norm, self.pi.obs_norm, self.pi.goal_norm, self.critic.norm)
        for norm, saved in zip(norms, self.fixture["metadata"]["normalizers"]):
            norm.mean.copy_(torch.tensor(saved["mean"], device="cuda"))
            norm.var.copy_(torch.tensor(saved["variance"], device="cuda"))
            norm.count.fill_(saved["count"])

    def world_update(self, meter):
        s = self.world
        with meter.span("world.forward"):
            pred = self.rollout(s["s"], s["actions"], s["xi"])
            loss, last = self.err(pred, s["s1"], s["mask"])
        self.opts[0].zero_grad(set_to_none=True)
        with meter.span("world.backward"):
            loss.backward()
        with meter.span("world.adam"):
            nn.utils.clip_grad_norm_(self.wm.parameters(), 1.0)
            self.opts[0].step()
        mask = s["mask"][:, -1]
        return [loss.item() / 8, ((last.detach() * mask).sum() / mask.sum().clamp(min=1)).item()]

    def replay_world_adam(self, baseline):
        """Causal numeric control: identical already-clipped native gradients."""
        self.reset()
        old = json.loads((Path(baseline) / "final.json").read_text())
        records = {r["name"]: r["blob"] for r in old["records"]}
        for i, p in enumerate(self.wm.parameters()):
            blob = records[f"world-{i}-gradient"]
            path = Path(baseline) / blob["file"]
            with path.open("rb") as f:
                assert hashlib.file_digest(f, "sha256").hexdigest() == blob["sha256"]
            assert int(blob["count"]) == p.numel()
            values = np.memmap(path, mode="c", dtype="<f8", shape=tuple(blob["shape"]))
            p.grad = torch.from_numpy(values).to(device=p.device, dtype=p.dtype)
        # No second clipping: the snapshot is the actual post-clip gradient.
        self.opts[0].step()
        return json.loads((Path(baseline) / "result.json").read_text())["rows"][-1]["metrics"]

    def prepare_actor(self):
        kin = G1Kinematics("cuda")
        if self.trained:
            S = tuple(torch.cat([self.read(f"reference-{i}-{key}") for i in range(33)]) for key in ("p", "r", "v", "w", "q", "qd"))
        else:
            S = tuple(x.repeat(33, *([1] * (x.ndim-1))) for x in unflatten_state(self.state))
        bodies = kin.forward(*S)
        motion = SimpleNamespace(root_p=S[0], root_R=S[1], q=S[4],
                                 body_p=bodies[0], body_R=bodies[1], body_v=bodies[2], body_w=bodies[3])
        motion.goal = lambda f, K: self.goals[f]
        mdp = MDP(kin, motion, torch.tensor(default_joint_pos_list(), device="cuda"))
        # Initial history is a shared tensor, not a second sensor reconstruction.
        original_obs = mdp.obs
        def obs(S, previous, xi, f):
            return self.history if f.ndim == 2 else original_obs(S, previous, xi, f)
        mdp.obs, mdp.add_noise = obs, lambda o: o
        f = torch.arange(4096, device="cuda")
        h = dict(s=self.state[:, None].expand(-1, 10, -1), xi=self.xi[:, None].expand(-1, 10, -1),
                 a_prev=self.previous[:, None].expand(-1, 10, -1), f=f[:, None].expand(-1, 10))
        s = dict(s=self.state, xi=self.xi, a_prev=self.previous, f=f)
        self.ctx.update(mdp=mdp, motion=motion, fixed_noise=self.noise,
                        args=SimpleNamespace(pi_batch=4096, no_critic=False, gamma=.99, lam=.95, critic_epochs=5, critic_minibatches=4),
                        opt_pi=self.opts[1], opt_v=self.opts[2], sample_valid_starts=lambda n: (s, h), orders=self.orders)
        comp = torch.compile if self.compiled else lambda f: f
        for target, source in (("imag_step", "_imag_step"), ("reward_term", "_reward_term"), ("critic_input_c", "_critic_input")):
            self.ctx[target] = comp(self.ctx[source])
        # Use the independently retained 8x512 implementation, replacing only
        # its randperm with the exported identical permutations.
        text = Path(os.environ["SHARED_SMC_CHUNKS"]).read_text()
        old = "perm = torch.randperm(n, device=dev)"
        assert text.count(old) == 1
        text = text.replace(old, 'perm = context["orders"][epoch]')
        ns = {}
        exec(compile(text, "pinned-smc-eight512-fixed-permutations", "exec"), ns)
        self.actor = ns["policy_update_microbatch"]
        self.actor_ready = True

    def actor_update(self, meter):
        self.ctx["_trace_span"] = meter.span
        # The existing SMC adapter retains its normalizer/GAE and 5x4 critic schedule.
        out = self.actor(self.ctx, 512)
        return [out[0].item(), out[1].item(), out[2].item(), out[4].item()]

    def compare(self, baseline, metrics):
        old = json.loads((Path(baseline) / "final.json").read_text())
        differences = []
        for record in old["records"]:
            name = record["name"]
            model, index, field = name.split("-")
            m = ("world", "policy", "critic").index(model)
            p = list(self.models[m].parameters())[int(index)]
            actual = {"parameter": lambda: p, "gradient": lambda: p.grad,
                      "moment1": lambda: self.opts[m].state[p]["exp_avg"],
                      "moment2": lambda: self.opts[m].state[p]["exp_avg_sq"]}[field]()
            blob = record["blob"]
            path = Path(baseline) / blob["file"]
            with path.open("rb") as f:
                assert hashlib.file_digest(f, "sha256").hexdigest() == blob["sha256"]
            expected = np.memmap(path, mode="r", dtype="<f8", shape=(int(blob["count"]),))
            a = actual.detach().flatten()
            count, maximum, relative, examples = 0, 0., 0., []
            error2, x2, y2, dot = 0., 0., 0., 0.
            for offset in range(0, a.numel(), 65536):
                x = a[offset:offset+65536].double().cpu().numpy()
                y = expected[offset:offset+65536]
                assert np.isfinite(x).all() and np.isfinite(y).all()
                delta, bound = np.abs(x-y), 2e-6 + 2e-4*np.abs(y)
                count += int(np.count_nonzero(delta > bound))
                maximum = max(maximum, float(delta.max()))
                relative = max(relative, float((delta/bound).max()))
                error2 += float(np.square(x-y).sum())
                x2 += float(np.square(x).sum())
                y2 += float(np.square(y).sum())
                dot += float((x*y).sum())
                if field == "parameter" and len(examples) < 8:
                    for local in np.flatnonzero(delta > bound)[:8-len(examples)]:
                        element = offset + int(local)
                        initial = self.frozen[f"{model}-{index}-parameter"].flatten()[element].item()
                        examples.append(dict(index=element, input_column=element % p.shape[-1],
                                             native=float(y[local]), smc=float(x[local]), initial=initial,
                                             native_update=float(y[local])-initial, smc_update=float(x[local])-initial,
                                             smc_gradient=p.grad.flatten()[element].item() if p.grad is not None else None))
            differences.append(dict(name=name, violations=count, max_abs=maximum, max_over_bound=relative, elements=a.numel(), examples=examples,
                                    l2_error=error2**.5, native_l2=y2**.5, smc_l2=x2**.5,
                                    cosine=dot/(x2*y2)**.5 if x2*y2 else None))
        norms = (self.wm.in_norm, self.wm.out_norm, self.pi.obs_norm, self.pi.goal_norm, self.critic.norm)
        for i, (norm, saved) in enumerate(zip(norms, old["metadata"]["normalizers"])):
            assert norm.count.item() == saved["count"], (i, "normalizer count")
            for field, actual in (("mean", norm.mean), ("variance", norm.var)):
                x = actual.detach().double().cpu().numpy()
                y = np.asarray(saved[field], dtype=np.float64)
                delta, bound = np.abs(x-y), 2e-6+2e-4*np.abs(y)
                differences.append(dict(name=f"norm-{i}-{field}", violations=int(np.count_nonzero(delta > bound)),
                                        max_abs=float(delta.max()), max_over_bound=float((delta/bound).max()), elements=x.size))
        expected_metrics = json.loads((Path(baseline) / "result.json").read_text())["rows"][-1]["metrics"]
        x, y = np.array(metrics), np.array(expected_metrics)
        delta, bound = np.abs(x-y), 2e-6+2e-4*np.abs(y)
        differences.append(dict(name="metrics", violations=int(np.count_nonzero(delta > bound)),
                                max_abs=float(delta.max()), max_over_bound=float((delta/bound).max()), elements=x.size))
        for opt, metadata in zip(self.opts, old["optimizer_metadata"]):
            for p, expected in zip(opt.param_groups[0]["params"], metadata["states"]):
                actual = opt.state.get(p)
                assert bool(actual) == expected["present"]
                if actual:
                    assert int(actual["step"].item()) == int(expected["step"])
        return dict(passed=not any(d["violations"] for d in differences), atol=2e-6, rtol=2e-4, tensors=differences)


def main():
    phase = os.environ["MOONROBO_SHARED_MODE"]
    mode = os.environ.get("MOONROBO_SHARED_OBSERVER", "off")
    assert phase in ("world", "actor") and mode in ("off", "events", "ranges", "aten")
    output = Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    assert not (output / "result.json").exists()
    probe = SharedProbe(os.environ["MOONROBO_SHARED_INPUT"], os.environ.get("SHARED_SMC_COMPILED", "1") == "1")
    if phase == "actor":
        probe.prepare_actor()
    rows = []
    repetitions = int(os.environ.get("MOONROBO_SHARED_REPETITIONS", "13"))
    assert repetitions in (1, 13)
    replay = os.environ.get("SHARED_REPLAY_NATIVE_GRADIENTS", "0") == "1"
    assert not replay or (phase == "world" and repetitions == 1)
    for iteration in range(0 if replay else repetitions):
        probe.reset()
        torch.cuda.synchronize()
        assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
        observing = mode != "off" and iteration >= 3
        meter = Meter(mode if observing else "off",
                      drain_backward=mode == "aten" and iteration == 3 and os.environ.get("SHARED_CAPTURE_BACKWARD_DRAIN") == "1")
        observer = torch.autograd.profiler.emit_nvtx(record_shapes=False) if mode == "aten" and observing else contextlib.nullcontext()
        with observer:
            capture = observing and iteration == 3
            if capture:
                torch.cuda.nvtx.range_push("shared.compute.capture")
            start = time.perf_counter_ns()
            metrics = (probe.world_update if phase == "world" else probe.actor_update)(meter)
            submitted = time.perf_counter_ns()
            torch.cuda.synchronize()
            drained = time.perf_counter_ns()
            if capture:
                torch.cuda.nvtx.range_pop()
        rows.append(dict(iteration=iteration, steady=iteration >= 3, metrics=metrics,
                         observer_active=observing, host_call_ms=(submitted-start)/1e6, drain_ms=(drained-submitted)/1e6,
                         wall_ms=(drained-start)/1e6, profile=meter.report(), capture_backward_drained=meter.capture_drained))
        print("SHARED_ROW", iteration, (drained-start)/1e6, flush=True)
    if replay:
        metrics = probe.replay_world_adam(os.environ["SHARED_NATIVE_BASELINE"])
    compare = probe.compare(os.environ["SHARED_NATIVE_BASELINE"], metrics)
    result = dict(schema="moonrobo.shared-compute-result.v1", implementation="smc", phase=phase, observer=mode,
                  compiled=probe.compiled, rows=rows, numerical_comparison=compare, synthetic_controlled_inputs=not probe.trained,
                  source_checkpoint=probe.fixture.get("source_checkpoint"), host_call_includes_implicit_waits=True,
                  identical_native_gradient_adam_replay=replay, forward_and_backward_executed=not replay,
                  rotation_control=probe.rotation_control,
                  layernorm_control=probe.layernorm_control,
                  same_initial_state_each_repeat=True, includes_sampling_or_upload=False,
                  allocated_peak=torch.cuda.max_memory_allocated(), reserved_peak=torch.cuda.max_memory_reserved(),
                  cuda_free_bytes=torch.cuda.mem_get_info()[0])
    with (output / "result.json").open("x") as f:
        json.dump(result, f, indent=2)
    assert torch.cuda.mem_get_info()[0] > 16 * 1024**3
    assert compare["passed"], "fixed cross-language numerical limits failed; evidence retained"


if __name__ == "__main__":
    main()
