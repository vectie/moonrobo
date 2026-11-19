"""Unit checks for the transport's new dual-elbow envelope, without DDS I/O."""
import copy
import time
import unittest
from january_transport import validate_frame


def row():
    now=str(time.time_ns()//1000000)
    motors=[dict(motor_id=i,pos=-.1 if i in (3,14) else 0.,vel=0.,tau=0.,
                 kp=0. if i==23 else 50.,kd=1. if i in (9,10,20,21) else 5.) for i in range(24)]
    return dict(kind="target",stage="drums",profile="suspended",action=11,axes=[0,0],
                receipt_ms=now,telemetry_receipt_ms=now,telemetry_source_ns="1",sequence=0,motors=motors)


class DrumTransportTest(unittest.TestCase):
    def test_valid_baseline_and_each_arm(self):
        first=row()
        baseline=validate_frame(first,None,None,"drums")
        for slot in (3,14):
            sample=copy.deepcopy(first)
            sample["motors"][slot]["pos"]-=.1
            validate_frame(sample,baseline,None,"drums")

    def test_shadow_and_wrong_joints_and_simultaneous_strokes_rejected(self):
        first=row()
        baseline=validate_frame(first,None,None,"drums")
        for fault in range(5):
            sample=copy.deepcopy(first)
            if fault==0:sample["shadow"]=True
            if fault==1:sample["motors"][12]["pos"]+=.01
            if fault==2:sample["motors"][14]["pos"]+=1
            if fault==3:sample["motors"][14]["kp"]+=1
            if fault==4:
                sample["motors"][3]["pos"]-=.1
                sample["motors"][14]["pos"]-=.1
            with self.assertRaises(AssertionError):
                validate_frame(sample,baseline,None,"drums")


if __name__=="__main__":unittest.main()
