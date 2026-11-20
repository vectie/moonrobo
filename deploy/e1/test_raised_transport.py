"""Raised reference validation without DDS participants or robot I/O."""
import copy,time,unittest
from test_drum_transport import row
from january_transport import validate_frame,raised_targets,typing_targets

class RaisedTransportTest(unittest.TestCase):
    def initial(self):
        sample=row();sample["stage"]="raised-drums";sample["reference_frame"]=-1
        return sample

    def test_raised_hold_alternating_drops_and_return(self):
        first=self.initial();baseline=validate_frame(first,None,None,"raised-drums")
        for frame in (0,3000,3100,3500,4300,5100,5900,6300,8550):
            sample=copy.deepcopy(first);sample["reference_frame"]=frame
            left,right=raised_targets(frame,baseline)
            sample["motors"][3]["pos"]=left;sample["motors"][14]["pos"]=right
            validate_frame(sample,baseline,None,"raised-drums")

    def test_wrong_frame_shadow_other_joints_and_reference_rejected(self):
        first=self.initial();baseline=validate_frame(first,None,None,"raised-drums")
        for fault in range(4):
            sample=copy.deepcopy(first)
            if fault==0:sample["shadow"]=True
            if fault==1:sample["reference_frame"]=8551
            if fault==2:sample["motors"][12]["pos"]+=.01
            if fault==3:sample["reference_frame"]=3000
            with self.assertRaises(AssertionError):validate_frame(sample,baseline,None,"raised-drums")

    def test_skipped_reference_and_expired_receipt_rejected(self):
        first=self.initial();baseline=validate_frame(first,None,None,"raised-drums")
        now=time.time_ns()//1000000
        first["receipt_ms"]=str(now-1)
        sample=copy.deepcopy(first);sample["sequence"]=1;sample["receipt_ms"]=str(now)
        sample["telemetry_source_ns"]="2";sample["reference_frame"]=3000
        sample["motors"][3]["pos"],sample["motors"][14]["pos"]=raised_targets(3000,baseline)
        with self.assertRaises(AssertionError):validate_frame(sample,baseline,first,"raised-drums")
        sample=self.initial();sample["receipt_ms"]=str(now-41)
        with self.assertRaises(AssertionError):validate_frame(sample,baseline,None,"raised-drums")

class TypingTransportTest(unittest.TestCase):
    def initial(self):
        sample=row();sample["stage"]="typing-elbows";sample["reference_frame"]=-1
        return sample

    def test_typing_entry_hold_and_exact_return(self):
        first=self.initial();baseline=validate_frame(first,None,None,"typing-elbows")
        for frame in (0,1500,3000,3100,4600,6100):
            sample=copy.deepcopy(first);sample["reference_frame"]=frame
            sample["motors"][3]["pos"],sample["motors"][14]["pos"]=typing_targets(frame,baseline)
            validate_frame(sample,baseline,None,"typing-elbows")

    def test_non_elbow_change_wrong_target_and_shadow_are_rejected(self):
        first=self.initial();baseline=validate_frame(first,None,None,"typing-elbows")
        for fault in range(5):
            sample=copy.deepcopy(first)
            if fault==0:sample["motors"][5]["pos"]+=.01
            if fault==1:sample["motors"][0]["pos"]+=.01
            if fault==2:sample["motors"][3]["pos"]-=.01
            if fault==3:sample["shadow"]=True
            if fault==4:sample["reference_frame"]=6101
            with self.assertRaises(AssertionError):validate_frame(sample,baseline,None,"typing-elbows")

if __name__=="__main__":unittest.main()
