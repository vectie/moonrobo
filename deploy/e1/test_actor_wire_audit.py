"""Network-free tests of captured actor frame/proposal identity and freshness."""
import copy
import unittest
from e1_command_packets import actor_wire_matches, motor_signature

class ActorWireTests(unittest.TestCase):
    def test_identical_fresh_proposal_matches_and_changed_wire_values_fail(self):
        values=[dict(motor_id=i,pos=0.,vel=0.,tau=0.,kp=50.,kd=5.) for i in range(24)]
        row=dict(receipt_ms="1000",telemetry_receipt_ms="1000",
                 inference=dict(inferred_at_ms="1000",input_receipt_ms="1000"))
        proposals={motor_signature(values):[row]}
        self.assertTrue(actor_wire_matches(values,1001000000,1001000,proposals))
        changed=copy.deepcopy(values);changed[19]["pos"]+=.001
        self.assertFalse(actor_wire_matches(changed,1001000000,1001000,proposals))
        self.assertFalse(actor_wire_matches(values,1041000000,1041000,proposals))
        self.assertFalse(actor_wire_matches(values,999000000,999000,proposals))
        self.assertFalse(actor_wire_matches(values,1001000000,999000,proposals))

    def test_fresh_heartbeat_cannot_mask_old_model_input(self):
        values=[dict(motor_id=i,pos=0.,vel=0.,tau=0.,kp=50.,kd=5.) for i in range(24)]
        row=dict(receipt_ms="1100",telemetry_receipt_ms="1100",
                 inference=dict(inferred_at_ms="1100",input_receipt_ms="1000"))
        self.assertFalse(actor_wire_matches(values,1101000000,1101000,{motor_signature(values):[row]}))

if __name__=="__main__":unittest.main()
