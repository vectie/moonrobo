import copy
import json
import pathlib
import tempfile
import unittest
from shadow_effort_validation import PositionHoldAudit, load_position_trial, validate_position_trial_profile, validate_shadow_effort, verify_seed_capture, LEGS
import time
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


def position_candidates():
    first=row()
    first.update(shadow=True,stage="hold",reported_leg_effort_shadow=None)
    seed_q=[m["pos"] for m in first["motors"]]
    settings=dict(format="moonrobo.e1-position-hold-shadow.v1",power_qualified=False,
        integral_gain_nm_per_rad_s=50.,maximum_error_rad=0.017453292519943295,
        bias_limit_nm=[7.5 if i in LEGS else 0. for i in range(24)],
        slew_limit_nm_per_s=[7.5 if i in LEGS else 0. for i in range(24)])
    rows=[]
    for tick in range(2):
        current=copy.deepcopy(first)
        source=1000000000+tick*20000000
        arrival=1000000000+tick*20000000
        current.update(sequence=tick,receipt_ms=str(arrival//1000000),
            telemetry_receipt_ms=str(arrival//1000000),telemetry_source_ns=str(source))
        q=seed_q.copy()
        q[7]-=.001*tick
        current["motors"][7]["tau"]=50.*(seed_q[7]-q[7])*.02 if tick else 0.
        current["position_hold_shadow"]=dict(settings=copy.deepcopy(settings),power_qualified=False,
            seed_packet_sequence=10,seed_arrival_ns="1000000000",seed_source_ns="1000000000",
            seed_position=seed_q.copy(),input_packet_sequence=10+tick,
            input_arrival_ns=str(arrival),input_source_ns=str(source),
            input_position=q,input_velocity=[0.]*24)
        rows.append(current)
    return rows


class PositionFeedbackTests(unittest.TestCase):
    def test_position_math_and_raw_binding_do_not_depend_on_reported_torque(self):
        rows=position_candidates()
        for torque in (None,[0.]*24,[90.]*24):
            audit=PositionHoldAudit()
            for current in rows:audit.observe(current)
            capture=[]
            for current in rows:
                meta=current["position_hold_shadow"]
                packet=dict(seq=meta["input_packet_sequence"],arrival_ns=meta["input_arrival_ns"],
                    source_ns=meta["input_source_ns"],q=meta["input_position"],qd=meta["input_velocity"],error=[0]*24)
                if torque is not None:packet["tau"]=torque
                capture.append(dict(motor_ids=list(range(24)),packet=packet))
            with tempfile.TemporaryDirectory() as directory:
                path=pathlib.Path(directory)/"status.ndjson"
                path.write_text("\n".join(map(json.dumps,capture))+"\n")
                audit.verify_capture(path)
                capture[1]["packet"]["q"]=capture[1]["packet"]["q"].copy()
                capture[1]["packet"]["q"][7]+=.0001
                path.write_text("\n".join(map(json.dumps,capture))+"\n")
                with self.assertRaises(AssertionError):audit.verify_capture(path)

    def test_forged_position_effort_gains_missing_mode_and_drift_are_rejected(self):
        for fault in ("position","effort","gains","shadow","drift","settings","reserved"):
            first,second=position_candidates()
            audit=PositionHoldAudit()
            audit.observe(first)
            if fault=="position":second["motors"][7]["pos"]+=.001
            if fault=="effort":second["motors"][7]["tau"]+=.001
            if fault=="gains":second["motors"][7]["kp"]+=1.
            if fault=="shadow":second["shadow"]=False
            if fault=="drift":second["position_hold_shadow"]["input_position"][7]-=.02
            if fault=="settings":second["position_hold_shadow"]["settings"]["integral_gain_nm_per_rad_s"]+=1.
            if fault=="reserved":second["motors"][23]["tau"]=.001
            with self.subTest(fault=fault),self.assertRaises(AssertionError):audit.observe(second)

    def test_position_shadow_cannot_be_promoted_even_after_zeroing_effort(self):
        current=position_candidates()[0]
        current["shadow"]=False
        with self.assertRaisesRegex(AssertionError,"unqualified position feedback"):
            validate_frame(current,None,None,"hold")


def trial_candidates():
    profile=json.loads(pathlib.Path(__file__).with_name("position-hold-trial.json").read_text())
    rows=position_candidates()
    start=time.time_ns()//1000000-20
    for tick,current in enumerate(rows):
        meta=current.pop("position_hold_shadow")
        meta["settings"]=copy.deepcopy(profile["feedback"])
        meta["trial_profile"]=copy.deepcopy(profile)
        meta["seed_arrival_ns"]=str(start*1000000)
        meta["input_arrival_ns"]=str((start+tick*20)*1000000)
        current.update(shadow=False,position_hold_trial=meta,
            receipt_ms=str(start+tick*20),telemetry_receipt_ms=str(start+tick*20))
        knee=-0.00476837158203125
        current["motors"][19]["pos"]=meta["seed_position"][19]=meta["input_position"][19]=knee
        current["current_pose_commissioning"]=dict(format="moonrobo.e1-current-pose-commissioning.v1",
            scope="unchanged-raw-hold-and-elbows-only",expected_knee_raw_rad=knee,evidence_sha256="a"*64)
    return profile,rows


class PositionHoldTrialTests(unittest.TestCase):
    def test_live_trial_requires_explicit_profile_and_independent_math(self):
        profile,(first,second)=trial_candidates()
        with self.assertRaisesRegex(AssertionError,"explicit finite"):
            validate_frame(first,None,None,"hold")
        validator=PositionHoldAudit(profile)
        baseline=validate_frame(first,None,None,"hold",position_validator=validator)
        validate_frame(second,baseline,first,"hold",position_validator=validator)
        self.assertGreater(second["motors"][7]["tau"],0)
        self.assertEqual([m["pos"] for m in baseline],[m["pos"] for m in second["motors"]])

    def test_trial_rejects_forged_effort_changed_positions_and_missing_metadata(self):
        for fault in ("effort","position","gain","metadata","nonleg","shadow"):
            profile,(first,second)=trial_candidates()
            validator=PositionHoldAudit(profile)
            baseline=validate_frame(first,None,None,"hold",position_validator=validator)
            if fault=="effort":second["motors"][7]["tau"]+=.1
            if fault=="position":second["motors"][7]["pos"]+=.001
            if fault=="gain":second["motors"][7]["kp"]+=1
            if fault=="metadata":second.pop("position_hold_trial")
            if fault=="nonleg":second["motors"][3]["tau"]+=.1
            if fault=="shadow":second["shadow"]=True
            with self.subTest(fault=fault),self.assertRaises(AssertionError):
                validate_frame(second,baseline,first,"hold",position_validator=validator)

    def test_profile_and_shadow_evidence_cannot_be_silently_changed(self):
        profile,_=trial_candidates()
        for field,value in (("maximum_active_ms",15000),("power_qualified",True)):
            changed=copy.deepcopy(profile)
            changed[field]=value
            with self.assertRaises(AssertionError):validate_position_trial_profile(changed)
        with tempfile.TemporaryDirectory() as directory:
            config=pathlib.Path(directory)/"trial.json"
            evidence=pathlib.Path(directory)/"proof.json"
            config.write_text(json.dumps(profile))
            evidence.write_text("{}")
            with self.assertRaisesRegex(AssertionError,"digest mismatch"):load_position_trial(config,evidence)


if __name__=="__main__":unittest.main()
