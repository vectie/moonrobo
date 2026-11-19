"""Return-adaptive reference resets, paper Appendix D.1.

Uses smc's 0.5 uniform / 0.4 difficulty / 0.1 historical mixture. Simultaneous
completed episodes in the same bin are averaged before the EMA update, so
result is independent of batch ordering and never last-writer-wins.
"""
from __future__ import annotations

import torch

from .motion import BIN_FRAMES


class ReturnBinSampler:
    def __init__(self, motion, gamma=0.99, max_step_reward=0.1, seed=0):
        if not 0 <= gamma < 1 or max_step_reward <= 0:
            raise ValueError("invalid discount or reward bound")
        self.motion = motion
        self.gamma = float(gamma)
        self.G_max = float(max_step_reward / (1 - gamma))
        self.bin_G = torch.zeros(motion.num_bins, device=motion.device)
        self.bin_w_avg = torch.full_like(self.bin_G, 1 / motion.num_bins)
        self.completed_count = torch.zeros_like(self.bin_G, dtype=torch.long)
        self.generator = torch.Generator(device=motion.device).manual_seed(seed)

    def probabilities(self, *, update_average=False):
        soft = torch.softmax(-25.0 * self.bin_G / self.G_max, 0)
        if update_average:
            self.bin_w_avg.mul_(0.999).add_(0.001 * soft)
        return 0.5 / self.motion.num_bins + 0.4 * soft + 0.1 * self.bin_w_avg / self.bin_w_avg.sum()

    def sample(self, n, min_remaining_steps=1):
        if n < 0 or min_remaining_steps < 1:
            raise ValueError("invalid reset batch or remaining horizon")
        m = self.motion
        if n == 0:
            empty = torch.empty(0, dtype=torch.long, device=m.device)
            return empty, empty.clone()
        ends = torch.minimum(m.bin_start + BIN_FRAMES,
                             m.clip_end[m.bin_clip] - min_remaining_steps + 1)
        probabilities = self.probabilities(update_average=True) * (ends > m.bin_start)
        if not probabilities.sum() > 0:
            raise ValueError("no reset bin has enough remaining steps")
        bins = torch.multinomial(probabilities, n, replacement=True, generator=self.generator)
        start = m.bin_start[bins]
        offsets = (torch.rand(n, device=m.device, generator=self.generator) *
                   (ends[bins] - start)).long()
        return start + offsets, bins

    @torch.no_grad()
    def update(self, start_bins, discounted_returns, episode_lengths=None,
               undiscounted_returns=None, terminated=None):
        bins = torch.as_tensor(start_bins, device=self.bin_G.device, dtype=torch.long).flatten()
        returns = torch.as_tensor(discounted_returns, device=self.bin_G.device,
                                  dtype=self.bin_G.dtype).flatten().clone()
        if bins.shape != returns.shape or not torch.isfinite(returns).all():
            raise ValueError("one finite discounted return required per completed episode")
        if not len(bins):
            return
        if (bins < 0).any() or (bins >= len(self.bin_G)).any():
            raise ValueError("invalid completed-episode bin")
        optional = (episode_lengths, undiscounted_returns, terminated)
        if any(x is not None for x in optional):
            if not all(x is not None for x in optional):
                raise ValueError("truncation bootstrap requires length, total return and termination")
            lengths = torch.as_tensor(episode_lengths, device=bins.device).flatten()
            totals = torch.as_tensor(undiscounted_returns, device=bins.device).flatten()
            terminal = torch.as_tensor(terminated, device=bins.device, dtype=torch.bool).flatten()
            if lengths.shape != bins.shape or totals.shape != bins.shape or terminal.shape != bins.shape:
                raise ValueError("completed episode fields differ in length")
            if (lengths <= 0).any() or not torch.isfinite(totals).all():
                raise ValueError("invalid completed episode length or return")
            returns += torch.where(terminal, 0., self.gamma ** lengths *
                                   (totals / lengths) / (1 - self.gamma))
        sums = torch.zeros_like(self.bin_G).scatter_add_(0, bins, returns)
        counts = torch.zeros_like(self.completed_count).scatter_add_(0, bins, torch.ones_like(bins))
        touched = counts > 0
        self.bin_G[touched] = 0.8 * self.bin_G[touched] + 0.2 * sums[touched] / counts[touched]
        self.completed_count += counts

    def state_dict(self):
        return {"format": "moonrobo.return-bin-sampler.v1", "gamma": self.gamma,
                "G_max": self.G_max, "clip_names": list(self.motion.names),
                "clip_sha256": list(self.motion.source_sha256),
                "clip_lengths": self.motion.clip_len.detach().cpu().clone(),
                "bin_G": self.bin_G.clone(), "bin_w_avg": self.bin_w_avg.clone(),
                "completed_count": self.completed_count.clone(),
                "generator": self.generator.get_state().clone()}

    def load_state_dict(self, state):
        if (state.get("format") != "moonrobo.return-bin-sampler.v1" or
                state["gamma"] != self.gamma or state["G_max"] != self.G_max or
                state["clip_names"] != self.motion.names or
                state["clip_sha256"] != self.motion.source_sha256 or
                not torch.equal(state["clip_lengths"].cpu(), self.motion.clip_len.cpu())):
            raise ValueError("sampler checkpoint and motion catalog/config differ")
        for key in ("bin_G", "bin_w_avg", "completed_count"):
            target = getattr(self, key)
            if state[key].shape != target.shape:
                raise ValueError("sampler checkpoint bin count differs")
            target.copy_(state[key].to(target.device))
        self.generator.set_state(state["generator"].cpu())
