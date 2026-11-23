"""Independent admission of position-only holding combined with live inference.

Only leg effort may adapt. The actor validator separately checks both elbow
positions against the model output, filtering, limits and previous actions.
"""
import hashlib
import json
import copy
import math
from shadow_effort_validation import PositionHoldAudit
from supported_elbow_validation import SupportedElbowValidator


class ActorHoldValidator:
    def __init__(self, profile):
        # Reuse exact v2 profile validation, without implying its reference
        # trajectory or nineteen-second deadline applies to the actor.
        SupportedElbowValidator(profile, True)
        assert profile["format"] == "moonrobo.e1-supported-elbow.v2"
        self.profile = copy.deepcopy(profile)
        self.feedback = PositionHoldAudit()
        self.previous = None

    def validate(self, row):
        assert row["stage"] == "actor-elbows" and type(row["shadow"]) is bool
        assert row.get("reported_leg_effort_shadow") is None
        assert row.get("position_hold_shadow") is None
        assert row.get("position_hold_trial") is None and row.get("supported_elbow_trial") is None
        meta = row["actor_position_hold"]
        assert meta["format"] == "moonrobo.e1-actor-position-hold.v1"
        assert meta["profile"] == self.profile and meta["settings"] == self.profile["feedback"]
        inference = row["inference"]
        assert meta["input_packet_sequence"] == inference["input_packet_sequence"]
        assert int(meta["input_arrival_ns"])//1000000 == int(inference["input_receipt_ms"])
        assert meta["update_ms"] == inference["adapter_tick_ms"]
        for slot in range(23):
            actual=meta["input_position"][slot]
            if slot in (3,14):
                assert -2.44<=actual<=0.
                previous_target=(self.previous or row)["motors"][slot]["pos"]
                if not row["shadow"]:assert abs(actual-previous_target)<=5.*math.pi/180
            else:assert abs(actual-meta["seed_position"][slot])<=5.*math.pi/180
        if self.previous is not None:
            old = self.previous
            if inference["inference_sequence"] == old["inference"]["inference_sequence"]:
                assert meta == old["actor_position_hold"] and row["motors"] == old["motors"]
                self.previous = row
                return
        # This projection is solely an independent calculation audit. Neither
        # the control owner nor the powered transport invokes a shadow owner.
        motors = [dict(m) for m in row["motors"]]
        for i in (3, 14):
            motors[i]["pos"] = meta["seed_position"][i]
        projected = dict(row, stage="hold", shadow=True, motors=motors,
                         position_hold_shadow=meta,
                         sequence=inference["inference_sequence"],
                         receipt_ms=meta["update_ms"],
                         telemetry_source_ns=meta["input_source_ns"],
                         telemetry_receipt_ms=str(int(meta["input_arrival_ns"])//1000000))
        self.feedback.observe(projected)
        self.previous = row

    def verify_capture(self, path):
        self.feedback.verify_capture(path)


def load_actor_hold(profile_path, audit_path, config_path, handback_path, peer):
    profile = json.loads(profile_path.read_text())
    ActorHoldValidator(profile)
    proof = json.loads(audit_path.read_text())
    assert proof["passed"] is True and proof["shadow"] is True
    assert proof["actor_position_hold"] is True and proof["raw_inputs_verified"] is True
    assert proof["actor_config_sha256"] == hashlib.sha256(config_path.read_bytes()).hexdigest()
    assert proof["hold_profile_sha256"] == hashlib.sha256(profile_path.read_bytes()).hexdigest()
    assert proof["fixed_position_records"] == 22 and proof["policy_updates"] > 500
    # The supported path has its own real hold-and-return evidence. It must
    # never be represented as a certificate for the default one-degree path.
    receipt = json.loads(handback_path.read_text())
    assert receipt["stage"] == "supported-elbow" and receipt["result"] == "stage complete"
    assert receipt["live"] is True and receipt["participant_deleted"] is True
    assert receipt["peer_prefix"] == peer and receipt["supported_elbow_trial"] == profile
    return profile, receipt["current_pose_commissioning"]
