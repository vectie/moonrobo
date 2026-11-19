"""Chronological vector replay with episode-safe windows and restartable storage.

Based on the smc ReplayBuffer layout (MIT; see SMC_LICENSE). A terminal
transition remains a valid dynamics target; following reset states never do.
Physical failure (terminated) and time-limit/clip-end (truncated) are distinct.
"""

from __future__ import annotations

import json
import torch

from .mdp import STATE_DIM, XI_DIM

FIELDS = {
    "s": (STATE_DIM, torch.float32), "s1": (STATE_DIM, torch.float32),
    "a": (29, torch.float32), "a_prev": (29, torch.float32),
    "xi": (XI_DIM, torch.float32), "r": ((), torch.float32),
    "f": ((), torch.long), "ep_step": ((), torch.int32),
    "done": ((), torch.bool), "terminated": ((), torch.bool),
    "truncated": ((), torch.bool),
}


def require_actor_horizon(motion, horizon: int) -> dict:
    """H future transitions require H+1 states; do not filter shorter clips."""
    if horizon < 1 or motion.clip_start.shape != motion.clip_end.shape:
        raise ValueError("invalid actor horizon or reference clip boundaries")
    spans = motion.clip_end - motion.clip_start
    if bool((spans < 0).any()):
        raise ValueError("invalid reference clip span")
    result = dict(catalog_clips=len(spans), eligible_clips=int((spans >= horizon).sum()),
                  longest_clip_steps=int(spans.max()) if len(spans) else 0, horizon=horizon)
    if result['eligible_clips'] == 0:
        raise ValueError("reference catalog has no complete imagination horizon "
                         "(H+1 states required); " + json.dumps(result))
    return result


class ReplayBuffer:
    def __init__(self, T: int, N: int, device: str = "cpu"):
        if T < 1 or N < 1:
            raise ValueError("replay capacity and environment count must be positive")
        self.T, self.N, self.device = T, N, device
        self.data = {
            k: torch.zeros((T, N) + ((shape,) if isinstance(shape, int) else shape),
                           dtype=dtype, device=device)
            for k, (shape, dtype) in FIELDS.items()
        }
        self.ptr, self.size = 0, 0

    def add(self, tr: dict):
        done = tr["done"].bool()
        truncated = tr.get("truncated", tr.get("timeout", torch.zeros_like(done))).bool()
        terminated = tr.get("terminated", tr.get("term", done & ~truncated)).bool()
        if not torch.equal(done, terminated | truncated):
            raise ValueError("done must equal terminated | truncated")
        values = {**tr, "done": done, "terminated": terminated, "truncated": truncated}
        for k in FIELDS:
            self.data[k][self.ptr].copy_(values[k])
        self.ptr = (self.ptr + 1) % self.T
        self.size = min(self.size + 1, self.T)

    def _row(self, age: torch.Tensor) -> torch.Tensor:
        return (self.ptr - self.size + age) % self.T

    def can_sample_windows(self, k: int) -> bool:
        return k > 0 and self.size >= k

    def sample_windows(self, B: int, k: int):
        if not self.can_sample_windows(k):
            raise ValueError(f"replay needs at least {k} rows; has {self.size}; collect warm-up first")
        if B < 1:
            raise ValueError("batch size must be positive")
        t0 = torch.randint(0, self.size - k + 1, (B,), device=self.device)
        env = torch.randint(0, self.N, (B,), device=self.device)
        rows = self._row(t0[:, None] + torch.arange(k, device=self.device))
        e = env[:, None].expand_as(rows)
        out = {key: self.data[key][rows, e] for key in FIELDS}
        # Require episode and reference continuity, even when the collector omitted
        # a done flag at a manually reset boundary. Keep the boundary transition.
        contiguous = (~out["done"][:, :-1]
                      & (out["ep_step"][:, 1:] == out["ep_step"][:, :-1] + 1)
                      & (out["f"][:, 1:] == out["f"][:, :-1] + 1))
        out["mask"] = torch.cumprod(torch.cat((torch.ones(B, 1, device=self.device),
                                               contiguous.float()), -1), -1)
        return out

    def _start_validity(self, motion=None, horizon: int = 0):
        if horizon < 0:
            raise ValueError("actor horizon cannot be negative")
        ages = torch.arange(self.size, device=self.device)
        rows = self._row(ages)
        frames = self.data["f"][rows]
        valid = torch.ones_like(frames, dtype=torch.bool)
        remaining = None
        if motion is not None:
            remaining = motion.clip_end[motion.clip_id[frames]] - frames
            valid &= remaining >= horizon
        return valid, remaining

    def actor_start_status(self, motion, horizon: int):
        if horizon < 1:
            raise ValueError("actor horizon must be positive")
        valid, remaining = self._start_validity(motion, horizon)
        if bool((remaining < 0).any()):
            raise ValueError("actor replay frame lies outside its reference clip")
        return dict(candidates=int(valid.sum()), replay_rows=self.size, horizon=horizon,
                    max_remaining_steps=int(remaining.max()) if self.size else 0)

    def ensure_actor_ready(self, motion, horizon: int, chunk_steps: int, collect, *,
                           any_need=lambda need: need, after_collect=lambda: None, context=None):
        """Bounded refill preserving smc's conditional-uniform valid-start rule.

        Budget: max(replay capacity, H) extra vector steps, in model-window
        chunks. DDP must pass an any-rank reduction and identical chunk sizes;
        locally ready ranks also collect while a peer needs data. No RNG is
        consumed by readiness checks. Extra data lowers effective update/data.
        """
        if chunk_steps < 1 or chunk_steps > self.T:
            raise ValueError("actor refill chunk must be positive and fit replay capacity")
        initial = self.actor_start_status(motion, horizon)['candidates']
        budget, added = max(self.T, horizon), 0
        while True:
            status = self.actor_start_status(motion, horizon)
            report = dict(initial_candidates=initial, **status,
                          extra_collection_steps=added, extra_physical_transitions=added*self.N,
                          collection_step_budget=budget)
            # Every rank takes the collective before deciding to fail, even if
            # its local replay is ready and only a peer exhausted the budget.
            if not any_need(status['candidates'] == 0):
                return report
            if added >= budget:
                raise RuntimeError("actor readiness exhausted finite collection budget; "
                                   "a local or peer replay has no complete imagination horizon: "
                                   + json.dumps(dict(**report, context=context)))
            steps = min(chunk_steps, budget-added)
            collect(steps)
            added += steps
            after_collect()

    def sample_starts(self, B: int, hist: int, *, motion=None, horizon: int = 0):
        if self.size == 0 or B < 1 or hist < 1:
            raise ValueError("nonempty replay and positive batch/history are required")
        valid, _ = self._start_validity(motion, horizon)
        candidates = valid.nonzero(as_tuple=False)
        if not len(candidates):
            raise ValueError("replay has no starts with a complete imagination horizon inside one clip")
        selected = candidates[torch.randint(len(candidates), (B,), device=self.device)]
        age, env = selected[:, 0], selected[:, 1]
        row = self._row(age)
        history_age = [age]
        cursor = age.clone()
        active = torch.ones(B, dtype=torch.bool, device=self.device)
        for _ in range(hist - 1):
            prior_age = (cursor - 1).clamp(min=0)
            now, prior = self._row(cursor), self._row(prior_age)
            active &= ((cursor > 0) & ~self.data["done"][prior, env]
                       & (self.data["ep_step"][now, env] == self.data["ep_step"][prior, env] + 1)
                       & (self.data["f"][now, env] == self.data["f"][prior, env] + 1))
            cursor = torch.where(active, prior_age, cursor)
            history_age.append(cursor)
        hrows = self._row(torch.stack(history_age[::-1], -1))
        henv = env[:, None].expand_as(hrows)
        fields = ("s", "a_prev", "xi", "f")
        return ({k: self.data[k][row, env] for k in fields},
                {k: self.data[k][hrows, henv] for k in fields})

    def state_dict(self):
        # Save only occupied rows in chronological order, avoiding unused large
        # allocations in early checkpoints. This snapshot is independent of writes.
        rows = self._row(torch.arange(self.size, device=self.device))
        return {"format": "moonrobo.aligned-replay.v1", "capacity": self.T,
                "num_envs": self.N, "size": self.size,
                "data": {k: value[rows].detach().cpu().clone() for k, value in self.data.items()}}

    def load_state_dict(self, state):
        if state["format"] != "moonrobo.aligned-replay.v1" or state["num_envs"] != self.N:
            raise ValueError("incompatible replay checkpoint")
        n = min(int(state["size"]), self.T)
        for key in FIELDS:
            if n:
                self.data[key][:n].copy_(state["data"][key][-n:])
        self.size, self.ptr = n, n % self.T
