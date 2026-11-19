"""Dump original full-actor FX while retaining frozen kernel/padding caches.

Only frontend graph-cache reuse is disabled so readable graphs are actually
written. The original boundary probe checks this diagnostic against SMC-b.
These diagnostic timings are not benchmark results.
"""
import torch
import torch._functorch.config
from actor_boundary_probe_a import main

torch._inductor.config.fx_graph_cache = False
torch._functorch.config.enable_autograd_cache = False
main()
