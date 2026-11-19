"""Bounded training-only physics replay for short model/policy alternation."""

import torch

from dynamics import imagine


class OnlineDynamics:
    def __init__(self, model, original, config, seed):
        self.model, self.original, self.config = model, original, config
        self.generator = torch.Generator().manual_seed(config["online_sampling_seed"] + seed)
        self.optimizer = torch.optim.Adam(model.parameters(), lr=config["online_model_learning_rate"])
        self.recent = None
        self.rounds, self.optimizer_steps = 0, 0
        self.initial_buffers = {k: v.clone() for k, v in model.named_buffers()}

    def append(self, episodes):
        fields = ["state", "action", "target", "context"]
        parts = {key: [] for key in fields}
        horizon = self.original.horizon
        for episode in episodes:
            if episode["split"] != "train":
                raise ValueError("online dynamics must not consume held-out episodes")
            steps = episode["steps"]
            if len(steps) < horizon:
                continue
            times = torch.tensor([s["time_s"] for s in steps], dtype=torch.float64)
            done = torch.tensor([s["terminated"] or s["truncated"] for s in steps])
            gaps = (times.unfold(0, horizon, 1).diff(dim=1) - self.original.layout["dt_s"]).abs()
            valid = (gaps <= self.original.layout["dt_s"] * 1e-6).all(1) & ~done.unfold(0, horizon, 1)[:, :-1].any(1)
            count = int(valid.sum())
            if not count:
                continue
            for key, source in [("state", "state"), ("action", "applied_action"), ("target", "next_state")]:
                tensor = torch.tensor([s[source] for s in steps], dtype=torch.float32)
                parts[key].append(tensor.unfold(0, horizon, 1).transpose(1, 2)[valid])
            parts["context"].append(torch.tensor(episode["context"], dtype=torch.float32)[None].expand(count, -1))
        if not parts["state"]:
            raise ValueError("no complete online dynamics windows")
        fresh = {key: torch.cat(parts[key]) for key in fields}
        for key in fields:
            value = torch.cat((self.recent[key], fresh[key])) if self.recent is not None else fresh[key]
            fresh[key] = value[-self.config["online_replay_windows"]:]
        self.recent = fresh

    def update(self, episodes):
        self.append(episodes)
        model = self.model
        for p in model.parameters():
            p.requires_grad_(True)
        old_count = self.config["batch_size"] // 2
        new_count = self.config["batch_size"] - old_count
        for _ in range(self.config["online_model_updates"]):
            old = torch.randint(len(self.original.state), (old_count,), generator=self.generator)
            new = torch.randint(len(self.recent["state"]), (new_count,), generator=self.generator)
            state = torch.cat((self.original.state[old], self.recent["state"][new]))
            action = torch.cat((self.original.action[old], self.recent["action"][new]))
            target = torch.cat((self.original.target[old], self.recent["target"][new]))
            context = torch.cat((self.original.context[old], self.recent["context"][new]))
            loss = ((imagine(model, state[:, 0], action, context) - target) / model.state_scale).square().mean()
            if not torch.isfinite(loss):
                raise ValueError("nonfinite online dynamics loss")
            self.optimizer.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            self.optimizer.step()
            self.optimizer_steps += 1
        for p in model.parameters():
            p.requires_grad_(False)
            p.grad = None
        if any(not torch.equal(value, dict(model.named_buffers())[key]) for key, value in self.initial_buffers.items()):
            raise ValueError("online updates changed frozen normalization")
        self.rounds += 1
        return dict(round=self.rounds, optimizer_steps=self.optimizer_steps,
                    recent_windows=len(self.recent["state"]), training_loss=float(loss.detach()),
                    normalization_unchanged=True)
