"""Independent validation of an unqualified, non-publishable effort hypothesis."""
import json
import math

LEGS = tuple(range(5, 11)) + tuple(range(16, 22))


class PositionHoldAudit:
    """Independently replay position-only effort; bind inputs to saved raw status.

    This verifies a shadow calculation, never the response of a powered joint.
    Reported torque is deliberately not an input to the calculation or admission.
    """
    def __init__(self):
        self.seed = self.settings = self.baseline = self.previous = None
        self.bias = [0.]*24
        self.inputs = {}
        self.count = 0
        self.maximum_bias_nm = 0.

    def observe(self, row):
        assert row["shadow"] is True and row["stage"] == "hold"
        assert row["action"] == 11 and row["axes"] == [0., 0.]
        assert row.get("reported_leg_effort_shadow") is None
        meta = row["position_hold_shadow"]
        assert meta["power_qualified"] is False
        settings = meta["settings"]
        assert settings["format"] == "moonrobo.e1-position-hold-shadow.v1"
        assert settings["power_qualified"] is False
        gain = settings["integral_gain_nm_per_rad_s"]
        assert math.isfinite(gain) and gain > 0
        tolerance = settings["maximum_error_rad"]
        assert math.isfinite(tolerance) and 0 < tolerance <= math.pi/180
        limits, rates = settings["bias_limit_nm"], settings["slew_limit_nm_per_s"]
        assert len(limits) == len(rates) == 24
        for i, (limit, rate) in enumerate(zip(limits, rates)):
            assert math.isfinite(limit) and math.isfinite(rate)
            if i in LEGS:
                peak = 150. if i in (7, 8, 18, 19) else 90. if i in (5, 6, 16, 17) else 70.
                assert 0 < limit <= peak and rate > 0
            else:
                assert limit == rate == 0.
        seed = {key: value for key, value in meta.items() if key.startswith("seed_")}
        q, qd = meta["input_position"], meta["input_velocity"]
        assert len(q) == len(qd) == len(seed["seed_position"]) == 24
        assert all(map(math.isfinite, q+qd+seed["seed_position"]))
        source, arrival = int(meta["input_source_ns"]), int(meta["input_arrival_ns"])
        receipt = arrival//1000000
        assert source > 0 and receipt >= 0
        assert int(row["telemetry_source_ns"]) == source
        assert int(row["telemetry_receipt_ms"]) == receipt
        assert 0 <= int(row["receipt_ms"]) - receipt <= 40
        if self.seed is None:
            self.seed, self.settings = seed, settings
            assert meta["input_packet_sequence"] == seed["seed_packet_sequence"]
            assert meta["input_arrival_ns"] == seed["seed_arrival_ns"]
            assert meta["input_source_ns"] == seed["seed_source_ns"]
            assert q == seed["seed_position"]
            dt = 0.
        else:
            assert seed == self.seed and settings == self.settings
            assert 0 < source-self.previous[0] <= 40000000
            assert 0 < receipt-self.previous[1] <= 40
            dt = (source-self.previous[0])/1e9
        motors = row["motors"]
        assert len(motors) == 24 and [m["motor_id"] for m in motors] == list(range(24))
        for i, motor in enumerate(motors):
            assert motor["pos"] == (0. if i == 23 else seed["seed_position"][i])
            assert motor["vel"] == 0. and motor["kp"] == (0. if i == 23 else 50.)
            assert motor["kd"] == (1. if i in (9, 10, 20, 21) else 5.)
            expected = 0.
            if i in LEGS:
                error = seed["seed_position"][i]-q[i]
                assert abs(error) <= tolerance
                accumulated = self.bias[i]+gain*error*dt
                capped = max(-limits[i], min(limits[i], accumulated))
                delta = max(-rates[i]*dt, min(rates[i]*dt, capped-self.bias[i]))
                expected = self.bias[i]+delta
            assert math.isfinite(motor["tau"]) and abs(motor["tau"]-expected) < 1e-12
            self.bias[i] = expected
            self.maximum_bias_nm = max(self.maximum_bias_nm, abs(expected))
        seq = meta["input_packet_sequence"]
        assert seq not in self.inputs
        self.inputs[seq] = (str(arrival), str(source), q, qd)
        self.previous = (source, receipt)
        self.count += 1

    def verify_capture(self, path):
        remaining = dict(self.inputs)
        with path.open() as capture:
            for line in capture:
                record = json.loads(line)
                packet = record["packet"]
                expected = remaining.get(packet["seq"])
                if expected is None:
                    continue
                assert record["motor_ids"] == list(range(24)) and packet["error"] == [0]*24
                actual = (packet["arrival_ns"], packet["source_ns"], packet["q"], packet["qd"])
                assert actual == expected, "position-feedback input differs from captured telemetry"
                del remaining[packet["seq"]]
        assert not remaining, "position-feedback inputs missing from raw capture"


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
