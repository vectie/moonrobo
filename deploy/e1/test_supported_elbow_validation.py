import copy
import json
import pathlib
import unittest
from january_transport import validate_frame
from supported_elbow_validation import SupportedElbowValidator, validate_profile, RAD
from test_shadow_effort_validation import trial_candidates


def candidates():
    profile=json.loads(pathlib.Path(__file__).with_name("supported-elbow.json").read_text())
    _,rows=trial_candidates()
    for i,row in enumerate(rows):
        meta=row.pop("position_hold_trial")
        meta.pop("trial_profile")
        meta.update(profile=copy.deepcopy(profile),settings=copy.deepcopy(profile["feedback"]),elapsed_ms=str(i*20))
        row.update(stage="supported-elbow",supported_elbow_trial=meta,reference_frame=-1)
        if i:
            meta["input_position"][7]=meta["seed_position"][7]-2.5*RAD
            row["motors"][7]["tau"]=50.*(meta["seed_position"][7]-meta["input_position"][7])*.02
    return profile,rows


class SupportedElbowTests(unittest.TestCase):
    def test_five_degree_profile_covers_all_non_target_joints_and_elbow_tracking(self):
        profile=json.loads(pathlib.Path(__file__).with_name("supported-elbow-5deg.json").read_text())
        for slot in (1,7,12,18,22,3):
            _,(first,second)=candidates()
            for row in (first,second):
                row["supported_elbow_trial"].update(profile=copy.deepcopy(profile),settings=copy.deepcopy(profile["feedback"]))
            validator=SupportedElbowValidator(profile,False)
            validator.validate(first)
            meta=second["supported_elbow_trial"]
            meta["input_position"][slot]=meta["seed_position"][slot]-4.5*RAD
            if slot in (7,18):second["motors"][slot]["tau"]=50.*(meta["seed_position"][slot]-meta["input_position"][slot])*.02
            validator.validate(second)
            # A new owner evaluates a fresh copy: no failed validation is reused.
            validator=SupportedElbowValidator(profile,False)
            validator.validate(first)
            meta["input_position"][slot]=meta["seed_position"][slot]-5.1*RAD
            with self.subTest(slot=slot),self.assertRaises(AssertionError):validator.validate(second)

    def test_explicit_three_degree_profile_admits_settling_without_changing_leg_targets(self):
        profile,(first,second)=candidates()
        validator=SupportedElbowValidator(profile,False)
        baseline=validate_frame(first,None,None,"supported-elbow",supported_validator=validator)
        validate_frame(second,baseline,first,"supported-elbow",supported_validator=validator)
        self.assertEqual([m["pos"] for m in first["motors"]],[m["pos"] for m in second["motors"]])

    def test_excess_drift_bad_effort_other_joint_motion_or_profile_change_fail(self):
        for fault in ("drift","effort","leg-target","other-arm","profile","shadow","reference"):
            profile,(first,second)=candidates()
            validator=SupportedElbowValidator(profile,False)
            validator.validate(first)
            if fault=="drift":second["supported_elbow_trial"]["input_position"][7]-=RAD
            if fault=="effort":second["motors"][7]["tau"]+=.1
            if fault=="leg-target":second["motors"][7]["pos"]+=.01
            if fault=="other-arm":second["supported_elbow_trial"]["input_position"][1]+=1.1*RAD
            if fault=="profile":second["supported_elbow_trial"]["profile"]["amplitude_deg"]=90.
            if fault=="shadow":second["shadow"]=True
            if fault=="reference":second["reference_frame"]=50
            with self.subTest(fault=fault),self.assertRaises(AssertionError):validator.validate(second)

    def test_unprofiled_transport_and_changed_budget_are_rejected(self):
        profile,(first,_)=candidates()
        with self.assertRaises(AssertionError):validate_frame(first,None,None,"supported-elbow")
        changed=copy.deepcopy(profile)
        changed["feedback"]["maximum_error_rad"]=4.*RAD
        with self.assertRaises(AssertionError):validate_profile(changed)


if __name__=="__main__":unittest.main()
