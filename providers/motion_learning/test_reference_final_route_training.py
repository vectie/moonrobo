"""Check matched independent actor/Adam/RNG forks used by the final-cycle study."""
import unittest

import torch

from reference_final_route_training import fork_actor_optimizer, generator_digest, optimizer_digest
from reference_learning import state_digest


class FinalRouteTrainingTest(unittest.TestCase):
    def test_fork_repeats_same_adam_update_and_sampler_without_aliasing(self):
        torch.manual_seed(477)
        actor = torch.nn.Linear(3, 2)
        optimizer = torch.optim.Adam(actor.parameters(), lr=.0003)
        inputs = torch.tensor([[.1, .2, -.3]])
        actor(inputs).square().sum().backward(); optimizer.step(); optimizer.zero_grad()
        generator = torch.Generator().manual_seed(23000)
        torch.randint(1000, (256,), generator=generator)
        branch, branch_optimizer, branch_generator = fork_actor_optimizer(actor, optimizer, generator)
        self.assertEqual(state_digest(branch), state_digest(actor))
        self.assertEqual(optimizer_digest(branch_optimizer), optimizer_digest(optimizer))
        self.assertEqual(generator_digest(branch_generator), generator_digest(generator))
        for module, opt in [(actor, optimizer), (branch, branch_optimizer)]:
            opt.zero_grad(); module(inputs).square().sum().backward(); opt.step()
        self.assertEqual(state_digest(branch), state_digest(actor))
        self.assertEqual(optimizer_digest(branch_optimizer), optimizer_digest(optimizer))
        self.assertTrue(torch.equal(torch.randint(1000, (64,), generator=generator),
            torch.randint(1000, (64,), generator=branch_generator)))
        original_digest = optimizer_digest(optimizer)
        next(iter(branch_optimizer.state.values()))["exp_avg"].add_(1)
        self.assertEqual(optimizer_digest(optimizer), original_digest)
        self.assertNotEqual(optimizer_digest(branch_optimizer), original_digest)
        original_actor = state_digest(actor)
        with torch.no_grad(): next(branch.parameters()).add_(1)
        self.assertEqual(state_digest(actor), original_actor)
        self.assertNotEqual(state_digest(branch), original_actor)


if __name__ == "__main__": unittest.main()
