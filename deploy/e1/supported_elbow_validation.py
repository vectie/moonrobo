"""Independent validation of a finite, explicitly crane-supported elbow trial."""
import hashlib
import json
import math
from shadow_effort_validation import LEGS, PositionHoldAudit

RAD=math.pi/180


def validate_profile(profile):
    assert profile["format"]=="moonrobo.e1-supported-elbow.v1" and profile["power_qualified"] is False
    assert (profile["hold_ms"],profile["motion_ms"],profile["return_hold_ms"],profile["maximum_total_ms"],profile["amplitude_deg"])==(3000,15000,500,19000,5.)
    feedback=profile["feedback"]
    assert feedback["format"]=="moonrobo.e1-position-hold-shadow.v1" and feedback["power_qualified"] is False
    assert feedback["integral_gain_nm_per_rad_s"]==50. and feedback["maximum_error_rad"]==3.*RAD
    budgets=[7.5 if i in (7,8,18,19) else 4.5 if i in (5,6,16,17) else 3.5 if i in (9,10,20,21) else 0. for i in range(24)]
    assert feedback["bias_limit_nm"]==feedback["slew_limit_nm_per_s"]==budgets


def load_profile(path, proof_path=None):
    content=path.read_bytes()
    profile=json.loads(content)
    validate_profile(profile)
    if proof_path is not None:
        proof=json.loads(proof_path.read_text())
        assert proof["passed"] is True and proof["live"] is False and proof["command_writers_created"] is False
        assert proof["profile_sha256"]==hashlib.sha256(content).hexdigest()
        assert proof["final_reference_frame"]==750 and proof["targets_returned_exactly"] is True
    return profile


class SupportedElbowValidator:
    def __init__(self,profile,shadow):
        validate_profile(profile)
        self.profile=profile
        self.shadow=shadow
        self.feedback=PositionHoldAudit()
        self.started=None
        self.previous_frame=-1
        self.previous_target=None
        self.last=None
        self.baseline=None

    def validate(self,row):
        assert row["stage"]=="supported-elbow" and row["shadow"] is self.shadow
        assert row["profile"]=="suspended" and row["action"]==11 and row["axes"]==[0,0]
        assert row.get("position_hold_shadow") is None and row.get("position_hold_trial") is None
        assert row.get("reported_leg_effort_shadow") is None
        meta=row["supported_elbow_trial"]
        assert meta["profile"]==self.profile and meta["settings"]==self.profile["feedback"]
        assert meta["power_qualified"] is False
        now=int(row["receipt_ms"])
        if self.started is None:self.started=now
        elapsed=now-self.started
        assert elapsed==int(meta["elapsed_ms"]) and 0<=elapsed<=18500
        frame=-1 if elapsed<3000 else min(750,(elapsed-3000)//20)
        assert row["reference_frame"]==frame and 0<=frame-self.previous_frame<=1
        seed=meta["seed_position"]
        actual=meta["input_position"]
        target=seed[3] + (-5.*RAD*(1.-math.cos(2.*math.pi*frame/750))/2. if frame>=0 else 0.)
        motors=row["motors"]
        assert -2.44<=actual[3]<=0 and -2.44<=target<=0
        assert abs(motors[3]["pos"]-target)<1e-12
        if not self.shadow:
            assert abs(actual[3]-(seed[3] if self.previous_target is None else self.previous_target))<=RAD
        assert all(abs(actual[i]-seed[i])<=RAD for i in range(23) if i not in LEGS and i!=3)
        # Project out the separately validated elbow position. This verifies
        # the identical fixed-leg integral using its existing independent math.
        projected=dict(row,stage="hold",shadow=True,position_hold_shadow=meta)
        projected_motors=[dict(m) for m in motors]
        projected_motors[3]["pos"]=seed[3]
        projected["motors"]=projected_motors
        self.feedback.observe(projected)
        if self.baseline is None:self.baseline=motors
        self.previous_frame=frame
        self.previous_target=target
        self.last=row

    def verify_capture(self,path):
        self.feedback.verify_capture(path)

    def returned(self):
        return self.previous_frame==750 and all(self.last["motors"][i]["pos"]==self.baseline[i]["pos"] for i in range(24))
