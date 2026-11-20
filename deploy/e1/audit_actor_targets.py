"""Audit saved actor proposals, without sockets or a claim of physical execution."""
import json
import math
import pathlib
import sys
from actor_validation import ActorValidator


def main():
    config_path, trace_path, output = map(pathlib.Path, sys.argv[1:])
    assert not output.exists()
    profile = json.loads(config_path.read_text())
    validator = ActorValidator(profile)
    baseline = previous = None
    policy = model_steps = packets = 0
    clipped = [0, 0]
    limited = [0, 0]
    raw_min, raw_max = [math.inf]*2, [-math.inf]*2
    applied_min, applied_max = [math.inf]*2, [-math.inf]*2
    stopped = False
    shadow = None
    for line in trace_path.open():
        row = json.loads(line)
        if row["kind"] == "stop":
            assert row["reason"] == "stage complete" and not stopped
            stopped = True
            continue
        assert not stopped and row["kind"] == "target" and row["stage"] == "actor-elbows"
        assert row["sequence"] == packets and row["profile"] == "suspended"
        assert row["action"] == 11 and row["axes"] == [0, 0]
        assert row["motor_ids"] == list(range(24))
        assert row["inference"]["input_packet_sequence"] <= row["packet_sequence"]
        if shadow is None:shadow = row["shadow"]
        assert row["shadow"] == shadow
        motors = row["motors"]
        assert len(motors) == 24 and [m["motor_id"] for m in motors] == list(range(24))
        for slot, motor in enumerate(motors):
            assert all(math.isfinite(motor[k]) for k in ("pos", "vel", "tau", "kp", "kd"))
            assert motor["vel"] == motor["tau"] == 0
            assert motor["kp"] == (0 if slot == 23 else 50)
            assert motor["kd"] == (1 if slot in (9, 10, 20, 21) else 5)
            if baseline and slot not in (3, 14):assert motor == baseline[slot]
        assert motors[23]["pos"] == 0
        if baseline is None:baseline = motors
        if previous:
            assert int(row["receipt_ms"]) > int(previous["receipt_ms"])
            assert int(row["telemetry_source_ns"]) > int(previous["telemetry_source_ns"])
        validator.validate(row, baseline, previous)
        sample = row["inference"]
        if previous is None or sample["inference_sequence"] != previous["inference"]["inference_sequence"]:
            model_steps += 1
            if sample["phase"] == "policy":
                policy += 1
                for i, slot in enumerate((3, 14)):
                    clipped[i] += sample["requested_elbow_rad"][i] != sample["bounded_elbow_rad"][i]
                    limited[i] += sample["rate_limited"][i]
                    raw_min[i] = min(raw_min[i], sample["raw_elbow_rad"][i])
                    raw_max[i] = max(raw_max[i], sample["raw_elbow_rad"][i])
                    applied_min[i] = min(applied_min[i], motors[slot]["pos"])
                    applied_max[i] = max(applied_max[i], motors[slot]["pos"])
        previous = row
        packets += 1
    assert stopped and policy > 500
    for slot in (3, 14):assert previous["motors"][slot] == baseline[slot]
    report = dict(passed=True, scope="saved command proposals; not a physical wire audit",
                  shadow=shadow, model_id=profile["model_id"], target_heartbeats=packets,
                  inference_updates=model_steps, policy_updates=policy, status_motor_records=24,
                  fixed_motor_records=22, max_fixed_target_change=0, targets_returned_exactly=True,
                  policy_authority=profile["adapter"]["policy_authority"],
                  position_bounded_policy_ticks=clipped, rate_limited_policy_ticks=limited,
                  raw_elbow_range_rad=dict(minimum=raw_min, maximum=raw_max),
                  applied_elbow_range_rad=dict(minimum=applied_min, maximum=applied_max))
    output.write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":main()
