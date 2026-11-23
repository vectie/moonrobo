"""Network-free admission tests for the explicit measured raw-pose hold."""
import copy
import unittest
from january_transport import validate_frame
from test_drum_transport import row

def current():
    sample=row()
    sample["stage"]="hold"
    sample["motors"][19]["pos"]=-0.00476837158203125
    sample["current_pose_commissioning"]={
        "format":"moonrobo.e1-current-pose-commissioning.v1",
        "scope":"unchanged-raw-hold-and-elbows-only",
        "expected_knee_raw_rad":sample["motors"][19]["pos"],
        "evidence_sha256":"a"*64}
    return sample

class CurrentPoseTests(unittest.TestCase):
    def test_exact_current_hold_is_admitted(self):
        sample=current()
        self.assertEqual(validate_frame(sample,None,None,"hold"),sample["motors"])

    def test_changed_raw_knee_other_leg_bad_profile_and_shadow_are_rejected(self):
        for fault in ("knee","other-leg","scope","digest","shadow","stage"):
            sample=current()
            if fault=="knee":sample["motors"][19]["pos"]+=.001
            if fault=="other-leg":sample["motors"][8]["pos"]=-.001
            if fault=="scope":sample["current_pose_commissioning"]["scope"]="whole-body"
            if fault=="digest":sample["current_pose_commissioning"]["evidence_sha256"]="not-evidence"
            if fault=="shadow":sample["shadow"]=True
            if fault=="stage":sample["stage"]="elbow"
            with self.subTest(fault=fault),self.assertRaises(AssertionError):
                validate_frame(sample,None,None,sample["stage"])

    def test_held_targets_cannot_change(self):
        sample=current()
        baseline=validate_frame(sample,None,None,"hold")
        changed=copy.deepcopy(sample)
        changed["motors"][18]["pos"]+=.001
        with self.assertRaises(AssertionError):validate_frame(changed,baseline,None,"hold")

if __name__=="__main__":unittest.main()
