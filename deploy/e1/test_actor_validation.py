"""Network-free rejection tests for the new actor command admission boundary."""
import copy
import unittest
from actor_validation import ActorValidator


def profile():
    return dict(format="moonrobo.e1-actor-elbows.v1", model_id="a"*64, model_om_sha256="a"*64,
                actor_robot=dict(joints=[str(i) for i in range(23)], default_q=[0.]*23, scales=[1.]*23),
                joint_calibration=dict(axes=[dict(actor_joint=str(i), motor_id=i, direction=1, zero=0.) for i in range(23)]),
                adapter=dict(lower_rad=[-1.5,-1.5], upper_rad=[0.,0.], maximum_speed_rad_s=[.04,.04],
                             response_ms=500, engage_ms=2000, policy_authority=1.), maximum_policy_ms=1000,
                reference_duration_ms=1000, reference_id="synthetic", approach_ms=0)


def initial():
    motors = [dict(motor_id=i,pos=-.2 if i<23 else 0.,vel=0.,tau=0.,kp=50. if i<23 else 0.,
                   kd=1. if i in (9,10,20,21) else 5.) for i in range(24)]
    prior = [m["pos"] for m in motors[:23]]+[0.]*6
    inference = dict(model_id="a"*64,inference_sequence=0,inferred_at_ms="10000",adapter_tick_ms="10000",input_receipt_ms="10000",scheduled_tick_ms="10000",
                     phase="baseline",policy_elapsed_ms="0",reference_step=0,reference="synthetic",
                     observation=[0.]*64+prior+[0.]*6,goals=[0.]*730,raw_actions=[0.]*29,
                     previous_applied_actions=prior,applied_actions=prior,raw_elbow_rad=[0.,0.],
                     requested_elbow_rad=[-.2,-.2],bounded_elbow_rad=[-.2,-.2],rate_limited=[False,False],authority=0.)
    return dict(receipt_ms="10000",inference=inference,motors=motors)


class AdmissionTests(unittest.TestCase):
    def test_valid_baseline_and_identical_heartbeat(self):
        admission=ActorValidator(profile())
        row=initial()
        admission.validate(row,row["motors"],None)
        heartbeat=copy.deepcopy(row)
        heartbeat["receipt_ms"]="10010"
        admission.validate(heartbeat,row["motors"],row)

    def test_changed_predictions_require_new_inference_sequence(self):
        row=initial()
        admission=ActorValidator(profile())
        admission.validate(row,row["motors"],None)
        broken=copy.deepcopy(row)
        broken["inference"]["raw_actions"][3]=-1.
        with self.assertRaises(AssertionError): admission.validate(broken,row["motors"],row)

    def test_bad_model_clock_action_feedback_and_inactive_channels_rejected(self):
        for name in ("model", "clock", "feedback", "mask", "target", "step", "phase"):
            row=initial()
            if name=="model":row["inference"]["model_id"]="b"*64
            if name=="clock":row["inference"]["inferred_at_ms"]="9959"
            if name=="feedback":row["inference"]["observation"][64]=1.
            if name=="mask":row["inference"]["raw_actions"][23]=1.
            if name=="target":row["motors"][3]["pos"]=-.5
            if name=="step":row["inference"]["reference_step"]=1
            if name=="phase":row["inference"]["phase"]="policy"
            with self.subTest(name=name), self.assertRaises(AssertionError):
                ActorValidator(profile()).validate(row,initial()["motors"],None)

    def test_stale_new_tick_is_not_accepted_as_heartbeat(self):
        row=initial()
        admission=ActorValidator(profile())
        admission.validate(row,row["motors"],None)
        late=copy.deepcopy(row)
        late["inference"]["inference_sequence"]=1
        late["inference"]["adapter_tick_ms"]="10041"
        late["inference"]["inferred_at_ms"]="10041"
        late["receipt_ms"]="10041"
        with self.assertRaises(AssertionError):admission.validate(late,row["motors"],row)


if __name__ == "__main__":unittest.main()
