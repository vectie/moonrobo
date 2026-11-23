"""Independent validation of an unqualified, non-publishable effort hypothesis."""
import json
import math

LEGS = tuple(range(5, 11)) + tuple(range(16, 22))


def verify_seed_capture(seed, path):
    with path.open() as trace:
        for line in trace:
            record = json.loads(line)
            packet = record["packet"]
            if packet["seq"] == seed["seed_packet_sequence"]:
                assert record["motor_ids"] == list(range(24)) and packet["error"] == [0]*24
                assert packet["arrival_ns"] == seed["seed_arrival_ns"]
                for key, field in (("q", "seed_position"), ("qd", "seed_velocity"),
                                   ("tau", "reported_torque")):
                    assert packet[key] == seed[field], "shadow seed differs from captured telemetry"
                return
    raise AssertionError("shadow seed sequence missing from capture")


def validate_shadow_effort(row, baseline=None):
    seed = row["reported_leg_effort_shadow"]
    assert row["shadow"] is True, "reported-effort candidate must remain shadow"
    assert seed["format"] == "moonrobo.e1-reported-leg-effort-shadow.v1"
    assert seed["power_qualified"] is False
    for key in ("seed_position", "seed_velocity", "reported_torque"):
        assert len(seed[key]) == 24 and all(map(math.isfinite, seed[key]))
    assert all(seed["reported_torque"][i] != 0 for i in LEGS)
    motors = row["motors"]
    assert len(motors) == 24 and [m["motor_id"] for m in motors] == list(range(24))
    for i, motor in enumerate(motors):
        expected = seed["reported_torque"][i] + motor["kd"]*seed["seed_velocity"][i] if i in LEGS else 0.
        assert math.isfinite(expected) and abs(motor["tau"]-expected) < 1e-12
        assert motor["vel"] == 0.
        assert motor["kp"] == (0. if i == 23 else 50.)
        assert motor["kd"] == (1. if i in (9, 10, 20, 21) else 5.)
        if i in LEGS:
            assert motor["pos"] == seed["seed_position"][i]
        if baseline and (row["stage"] == "hold" or i not in (3, 14)):
            assert motor == baseline[i], "held shadow motor record changed"
    assert motors[23]["pos"] == 0. and motors[23]["tau"] == 0.
    if baseline is None:
        if "packet_sequence" in row:
            assert row["packet_sequence"] == seed["seed_packet_sequence"]
        assert int(row["telemetry_receipt_ms"]) == int(seed["seed_arrival_ns"])//1000000
    return seed
