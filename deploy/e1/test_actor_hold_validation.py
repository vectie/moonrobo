"""Reject mixed inference/holding clocks and unvalidated effort changes."""
import copy
import json
import pathlib
import unittest
from unittest.mock import patch
from actor_hold_validation import ActorHoldValidator


def initial():
    profile=json.loads(pathlib.Path(__file__).with_name("supported-elbow-5deg.json").read_text())
    q=[-.1]*24
    meta=dict(format="moonrobo.e1-actor-position-hold.v1",power_qualified=False,
              profile=profile,settings=profile["feedback"],seed_packet_sequence=1,
              seed_arrival_ns="1000000000",seed_source_ns="1000000000",seed_position=q,
              input_packet_sequence=1,input_arrival_ns="1000000000",input_source_ns="1000000000",
              input_position=q.copy(),input_velocity=[0.]*24,update_ms="1000")
    row=dict(stage="actor-elbows",shadow=False,actor_position_hold=meta,action=11,axes=[0,0],
             inference=dict(inference_sequence=0,input_packet_sequence=1,input_receipt_ms="1000",adapter_tick_ms="1000"),
             motors=[dict(motor_id=i,pos=q[i] if i<23 else 0.,vel=0.,tau=0.,kp=50. if i<23 else 0.,
                          kd=1. if i in (9,10,20,21) else 5.) for i in range(24)])
    return profile,row


class ActorHoldTests(unittest.TestCase):
    def test_powered_transport_requires_both_explicit_feedback_and_model_validation(self):
        from january_transport import validate_frame
        from actor_validation import ActorValidator
        from test_actor_validation import initial as nn_initial, profile as nn_profile
        profile,row=initial()
        nn=nn_initial()
        row.update(kind="target",profile="suspended",sequence=0,receipt_ms="1000",
                   telemetry_receipt_ms="1000",telemetry_source_ns="1000000000")
        row["inference"]=nn["inference"]
        row["inference"]["input_packet_sequence"]=1
        for key in ("inferred_at_ms","adapter_tick_ms","scheduled_tick_ms","input_receipt_ms"):
            row["inference"][key]="1000"
        prior=ActorValidator(nn_profile()).actions(row["motors"])
        row["inference"].update(previous_applied_actions=prior,applied_actions=prior,
                                 requested_elbow_rad=[-.1,-.1],bounded_elbow_rad=[-.1,-.1])
        row["inference"]["observation"][64:93]=prior
        with patch("january_transport.time.time_ns",return_value=1000000000):
            with self.assertRaises(AssertionError):
                validate_frame(row,None,None,"actor-elbows",ActorValidator(nn_profile()))
            validate_frame(row,None,None,"actor-elbows",ActorValidator(nn_profile()),
                           actor_hold_validator=ActorHoldValidator(profile))
            broken=copy.deepcopy(row)
            broken["inference"]["raw_actions"][23]=1.
            with self.assertRaises(AssertionError):
                validate_frame(broken,None,None,"actor-elbows",ActorValidator(nn_profile()),
                               actor_hold_validator=ActorHoldValidator(profile))

    def test_numeric_feedback_updates_only_with_new_inference(self):
        profile,row=initial()
        owner=ActorHoldValidator(profile)
        owner.validate(row)
        owner.validate(copy.deepcopy(row))
        update=copy.deepcopy(row)
        meta=update["actor_position_hold"]
        meta.update(input_packet_sequence=11,input_arrival_ns="1020000000",input_source_ns="1020000000",update_ms="1020")
        meta["input_position"][7]-=.001
        update["inference"].update(inference_sequence=1,input_packet_sequence=11,input_receipt_ms="1020",adapter_tick_ms="1020")
        update["motors"][7]["tau"]=.001
        # Elbow motion is validated separately against actual NN actions.
        update["motors"][3]["pos"]=-.11
        owner.validate(update)
        self.assertAlmostEqual(owner.feedback.bias[7],.001)

    def test_tampering_stale_clocks_and_nonleg_effort_rejected(self):
        for kind in ("clock","nonleg","leg","position","profile","heartbeat"):
            profile,row=initial()
            owner=ActorHoldValidator(profile)
            if kind=="heartbeat":owner.validate(copy.deepcopy(row))
            if kind=="clock":row["actor_position_hold"]["input_packet_sequence"]=2
            if kind=="nonleg":row["motors"][4]["tau"]=.01
            if kind=="leg":row["motors"][7]["tau"]=.01
            if kind=="position":row["motors"][7]["pos"]+=.001
            if kind=="profile":row["actor_position_hold"]["settings"]["integral_gain_nm_per_rad_s"]=60.
            if kind=="heartbeat":row["motors"][7]["tau"]=.001
            with self.subTest(kind=kind),self.assertRaises(AssertionError):owner.validate(row)


if __name__=="__main__":unittest.main()
