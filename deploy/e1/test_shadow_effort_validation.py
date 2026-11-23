import copy
import json
import pathlib
import tempfile
import unittest
from shadow_effort_validation import validate_shadow_effort, verify_seed_capture, LEGS
from test_drum_transport import row
from january_transport import validate_frame


def candidate():
    result=row()
    result["shadow"]=True
    result["stage"]="hold"
    result["reported_leg_effort_shadow"]=dict(
        format="moonrobo.e1-reported-leg-effort-shadow.v1",power_qualified=False,
        seed_packet_sequence=1,seed_arrival_ns=str(int(result["telemetry_receipt_ms"])*1000000),
        seed_position=[m["pos"] for m in result["motors"]],seed_velocity=[.01]*24,
        reported_torque=[2.]*24)
    for i in LEGS:result["motors"][i]["tau"]=2.+result["motors"][i]["kd"]*.01
    return result


class ShadowEffortTests(unittest.TestCase):
    def test_seed_must_match_captured_values_and_complete_error_free_ids(self):
        seed=candidate()["reported_leg_effort_shadow"]
        record=dict(motor_ids=list(range(24)),packet=dict(seq=seed["seed_packet_sequence"],
            arrival_ns=seed["seed_arrival_ns"],q=seed["seed_position"],
            qd=seed["seed_velocity"],tau=seed["reported_torque"],error=[0]*24))
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/"status.ndjson"
            path.write_text(json.dumps(record)+"\n")
            verify_seed_capture(seed,path)
            for kind in ("torque","missing","error","ids"):
                changed=copy.deepcopy(record)
                if kind=="torque":changed["packet"]["tau"][7]+=.01
                if kind=="missing":changed["packet"]["seq"]+=1
                if kind=="error":changed["packet"]["error"][7]=1
                if kind=="ids":changed["motor_ids"][7]=8
                path.write_text(json.dumps(changed)+"\n")
                with self.subTest(kind=kind),self.assertRaises(AssertionError):verify_seed_capture(seed,path)

    def test_constant_seed_preserves_all_hold_records(self):
        first=candidate()
        validate_shadow_effort(first)
        validate_shadow_effort(copy.deepcopy(first),first["motors"])

    def test_zero_bad_effort_changed_target_and_power_claim_rejected(self):
        for kind in ("zero","effort","target","qualification","shadow"):
            current=candidate()
            if kind=="zero":current["reported_leg_effort_shadow"]["reported_torque"][7]=0.
            if kind=="effort":current["motors"][7]["tau"]+=.1
            if kind=="target":current["motors"][7]["pos"]+=.1
            if kind=="qualification":current["reported_leg_effort_shadow"]["power_qualified"]=True
            if kind=="shadow":current["shadow"]=False
            with self.subTest(kind=kind),self.assertRaises(AssertionError):validate_shadow_effort(current)

    def test_toggling_shadow_or_zeroing_torque_cannot_promote_hypothesis(self):
        current=candidate()
        current["shadow"]=False
        for motor in current["motors"]:motor["tau"]=0.
        with self.assertRaisesRegex(AssertionError,"unqualified reported effort"):
            validate_frame(current,None,None,"hold")


if __name__=="__main__":unittest.main()
