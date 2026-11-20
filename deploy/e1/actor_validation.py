"""Independent numeric admission of constrained actor commands. No network I/O."""
import math


class ActorValidator:
    def __init__(self, profile):
        assert profile["format"] == "moonrobo.e1-actor-elbows.v1"
        assert profile["model_id"] == profile["model_om_sha256"] and len(profile["model_id"]) == 64
        self.profile = profile
        self.settings = profile["adapter"]
        for key in ("lower_rad", "upper_rad", "maximum_speed_rad_s"):
            assert len(self.settings[key]) == 2 and all(map(math.isfinite, self.settings[key]))
        for i in range(2):
            assert -math.radians(130) <= self.settings["lower_rad"][i] < self.settings["upper_rad"][i] <= 0
            assert self.settings["maximum_speed_rad_s"][i] > 0
        assert self.settings["response_ms"] >= 20 and self.settings["engage_ms"] >= 20
        assert 0 < self.settings["policy_authority"] <= 1
        robot = profile["actor_robot"]
        self.axes = profile["joint_calibration"]["axes"]
        assert len(robot["joints"]) == len(self.axes) == 23
        assert sorted(a["motor_id"] for a in self.axes) == list(range(23))
        assert len(set(robot["joints"])) == 23
        assert len(robot["default_q"]) == len(robot["scales"]) == 23
        assert all(math.isfinite(x) for x in robot["default_q"] + robot["scales"])
        assert all(x > 0 for x in robot["scales"])
        self.robot = robot
        assert 0 < profile["maximum_policy_ms"] <= 30000
        assert 0 < profile["reference_duration_ms"]
        assert 0 <= profile["approach_ms"] <= 60000
        self.reference_duration = min(profile["reference_duration_ms"], profile["maximum_policy_ms"])
        self.duration = self.reference_duration + profile["approach_ms"]
        self.first_tick = None

    def actions(self, motors):
        actions = [0.] * 29
        for axis in self.axes:
            index = self.robot["joints"].index(axis["actor_joint"])
            assert axis["direction"] in (-1, 1) and math.isfinite(axis["zero"])
            q = axis["direction"] * (motors[axis["motor_id"]]["pos"] - axis["zero"])
            actions[index] = (q - self.robot["default_q"][index]) / self.robot["scales"][index]
        return actions

    @staticmethod
    def close(actual, expected):
        assert len(actual) == len(expected)
        assert all(math.isfinite(a) and abs(a-b) < 1e-9 for a, b in zip(actual, expected))

    def validate(self, row, baseline, previous):
        sample = row["inference"]
        assert sample["model_id"] == self.profile["model_id"]
        for name, count in (("observation", 99), ("goals", 730), ("raw_actions", 29),
                            ("previous_applied_actions", 29), ("applied_actions", 29)):
            assert len(sample[name]) == count and all(map(math.isfinite, sample[name]))
        assert sample["raw_actions"][23:] == [0.] * 6
        assert 0 <= int(row["receipt_ms"]) - int(sample["inferred_at_ms"]) <= 40, "actor inference expired"
        assert 0 <= int(row["receipt_ms"]) - int(sample["input_receipt_ms"]) <= 40, "actor input expired"
        assert 0 <= int(sample["inferred_at_ms"]) - int(sample["input_receipt_ms"]) <= 40
        assert 0 <= int(sample["inferred_at_ms"]) - int(sample["adapter_tick_ms"]) <= 40
        prior = previous["inference"] if previous else None
        self.close(sample["applied_actions"], self.actions(row["motors"]))
        if prior and sample["inference_sequence"] == prior["inference_sequence"]:
            assert sample == prior, "inference changed without a new inference sequence"
            assert row["motors"] == previous["motors"], "heartbeat changed actor targets"
            return
        assert sample["inference_sequence"] == (prior["inference_sequence"] + 1 if prior else 0)
        tick = int(sample["adapter_tick_ms"])
        dt = tick - int(prior["adapter_tick_ms"]) if prior else 0
        if prior:
            assert 10 <= dt <= 30, "actor tick interval invalid"
        else:
            self.first_tick = tick
        scheduled = int(sample["scheduled_tick_ms"])
        assert scheduled == self.first_tick + sample["inference_sequence"]*20
        assert 0 <= tick-scheduled <= 10, "actor schedule deadline missed"
        elapsed = scheduled - self.first_tick
        policy_elapsed = max(0, elapsed - 1000)
        phase = "baseline" if elapsed < 1000 else "policy" if policy_elapsed <= self.duration else "return"
        assert sample["phase"] == phase
        assert int(sample["policy_elapsed_ms"]) == policy_elapsed
        assert sample["reference_step"] == min(max(0, policy_elapsed-self.profile["approach_ms"]), self.reference_duration) // 20
        assert sample["reference"] == self.profile["reference_id"]
        assert prior or all(row["motors"][slot] == baseline[slot] for slot in (3, 14))
        preceding = previous["motors"] if prior else baseline
        self.close(sample["previous_applied_actions"], self.actions(preceding))
        # The observation's previous-action slice must describe that same command.
        self.close(sample["observation"][64:93], sample["previous_applied_actions"])
        u = min(1., policy_elapsed / self.settings["engage_ms"])
        authority = self.settings["policy_authority"]*u*u*u*(10+u*(-15+6*u)) if phase == "policy" else 0.
        assert abs(sample["authority"] - authority) < 1e-12
        raw = []
        for slot in (3, 14):
            axis = next(a for a in self.axes if a["motor_id"] == slot)
            index = self.robot["joints"].index(axis["actor_joint"])
            raw.append(axis["zero"] + axis["direction"] * (
                self.robot["default_q"][index] + self.robot["scales"][index] * sample["raw_actions"][index]))
        self.close(sample["raw_elbow_rad"], raw)
        requested = [baseline[slot]["pos"]+authority*(raw[i]-baseline[slot]["pos"]) for i,slot in enumerate((3,14))]
        self.close(sample["requested_elbow_rad"], requested)
        bounded = [max(self.settings["lower_rad"][i], min(self.settings["upper_rad"][i], value))
                   for i, value in enumerate(requested)]
        self.close(sample["bounded_elbow_rad"], bounded)
        for i, slot in enumerate((3, 14)):
            goal = bounded[i]
            old = preceding[slot]["pos"]
            maximum = self.settings["maximum_speed_rad_s"][i] * dt / 1000
            delta = (goal-old) * dt / (self.settings["response_ms"] + dt)
            shift = goal-old if phase == "return" and abs(goal-old) <= maximum else max(-maximum, min(maximum, delta))
            assert abs(row["motors"][slot]["pos"] - (old + shift)) < 1e-9, "actor adapter target differs"
            assert self.settings["lower_rad"][i] <= row["motors"][slot]["pos"] <= self.settings["upper_rad"][i]
