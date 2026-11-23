"""Receive-only E1 discovery and 24-motor preflight."""
import dataclasses,json,math,pathlib,sys,time
from cyclonedds.domain import DomainParticipant
from cyclonedds.builtin import BuiltinDataReader,BuiltinTopicDcpsPublication,BuiltinTopicDcpsSubscription
from cyclonedds.dynamic import get_types_for_typeid
from cyclonedds.qos import Qos,Policy
from cyclonedds.sub import DataReader
from cyclonedds.topic import Topic
from cyclonedds.util import duration

def main():
    output=pathlib.Path(sys.argv[1]);assert not output.exists()
    p=DomainParticipant(0)
    sources=BuiltinDataReader(p,BuiltinTopicDcpsPublication)
    sinks=BuiltinDataReader(p,BuiltinTopicDcpsSubscription)
    found={};reader=None;good=0;first=None;last=None
    torque_min=[math.inf]*24;torque_max=[-math.inf]*24
    torque_nonzero=[0]*24
    expected={"Motor_Cmd_Topic":"00070000f2f315417f2fd893ffc1e75f2c4f08",
              "Control_Mode_Topic":"00070000f2cc773776cccd5cf6f3ba76cf79c6"}
    end=time.monotonic()+15
    try:
        while time.monotonic()<end:
            for ep in sinks.take(64):
                if ep.sample_info.valid_data and ep.topic_name in expected:
                    assert ep.type_id.serialize().hex()==expected[ep.topic_name],"E1 interface changed"
                    found[ep.topic_name]=ep.key.hex
            for ep in sources.take(64):
                if ep.sample_info.valid_data and ep.topic_name in expected:
                    raise RuntimeError("another motor or mode publisher is already present")
                if ep.sample_info.valid_data and ep.topic_name=="Robot_Status_Topic":
                    assert reader is None or found["Robot_Status_Topic"]==ep.key.hex,"multiple status writers"
                    if reader is None:
                        schema,_=get_types_for_typeid(p,ep.type_id,duration(seconds=3))
                        reader=DataReader(p,Topic(p,ep.topic_name,schema),
                            qos=Qos(Policy.Reliability.BestEffort,Policy.Durability.Volatile))
                        found["Robot_Status_Topic"]=ep.key.hex
            if reader is not None:
                for s in reader.take(256):
                    if not s.sample_info.valid_data:continue
                    motors=s.motorstatearray.motorstates
                    assert len(motors)==24 and [m.motor_id for m in motors]==list(range(24))
                    assert all(m.error==0 and all(map(math.isfinite,(m.pos,m.vel,m.tau))) for m in motors)
                    for i,m in enumerate(motors):
                        torque_min[i]=min(torque_min[i],m.tau)
                        torque_max[i]=max(torque_max[i],m.tau)
                        torque_nonzero[i]+=int(m.tau!=0)
                    good+=1
                    last=[dataclasses.asdict(m) for m in motors]
                    if first is None:first=time.monotonic()
            if len(found)==3 and good>300 and time.monotonic()-first>=2:break
            time.sleep(.002)
        assert len(found)==3 and good>300 and first is not None and time.monotonic()-first>=2,"fresh complete E1 telemetry unavailable"
        prefix=found["Robot_Status_Topic"][:24]
        assert all(v[:24]==prefix for v in found.values()),"endpoints belong to different participants"
        output.write_text(json.dumps({"passed":True,"created_epoch":time.time(),"peer_prefix":prefix,
            "status_guid":found["Robot_Status_Topic"],"expected_reader_types":expected,"received_samples":good,
            "motor_ids":list(range(24)),"last_motors":last,"command_writers_created":False,
            "holding_effort":dict(reported_torque_min_nm=torque_min,reported_torque_max_nm=torque_max,
                nonzero_reported_torque_samples=torque_nonzero,
                factory_commanded_effort_available=False,
                reported_torque_semantics_qualified=False,
                zero_reported_torque_proves_zero_load=False),
            "physical_controller_mode":"operator must identify"},indent=2)+"\n")
    finally:p.__del__()
if __name__=="__main__":main()
