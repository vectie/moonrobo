"""Physics return diagnostics use complete rewards and an actual zero tail."""
import math
import unittest

import torch

from critic_probe import recorded_returns


class RecordedReturnTest(unittest.TestCase):
    def test_hard_and_soft_returns_at_a_physical_fall(self):
        steps = []
        for height, terminated in [(.8, False), (.3, True)]:
            state = [0.0] * 14
            state[2], state[3] = height, 1
            steps.append(dict(next_state=state, applied_action=[0], observation=[0],
                              goal=[0], terminated=terminated))
        hard, soft = recorded_returns({"steps": steps}, {"q_indices": [7]},
                                       {"gamma": .9, "target_height_m": .8})
        last_reward = 2 + math.exp(-(.5 / .15)**2)
        first_continuation = (1 / (1 + math.exp(-(.8 - .35) / .02))) * (1 / (1 + math.exp(-(1 - .5) / .05)))
        torch.testing.assert_close(hard, torch.tensor([3 + .9 * last_reward, last_reward]))
        torch.testing.assert_close(soft, torch.tensor([3 + .9 * first_continuation * last_reward, last_reward]))


if __name__ == "__main__":
    unittest.main()
