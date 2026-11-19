"""Receive-only E1 pose mirror. Creates no motor or mode publisher."""
import dataclasses,json,math,os,pathlib,sys,time
from cyclonedds.builtin import BuiltinDataReader,BuiltinTopicDcpsPublication
from cyclonedds.domain import DomainParticipant
from cyclonedds.dynamic import get_types_for_typeid
from cyclonedds.qos import Policy,Qos
from cyclonedds.sub import DataReader,Subscriber
from cyclonedds.topic import Topic
from cyclonedds.util import duration

def save(path,value):
    temporary=path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value,allow_nan=False,separators=(",",":")))
    os.replace(temporary,path)

def main():
    out=pathlib.Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
    mapping=json.loads(pathlib.Path(__file__).with_name("e1-joints.json").read_text())
    assert len(mapping)==23 and set(mapping.values())==set(range(23))
    save(out/"joint-map.json",mapping)
    participant=DomainParticipant(0)
    reader=None
    try:
        discovery=BuiltinDataReader(participant,BuiltinTopicDcpsPublication)
        end=time.monotonic()+25
        while reader is None and time.monotonic()<end:
            for endpoint in discovery.take(32):
                if not endpoint.sample_info.valid_data or endpoint.topic_name!="Robot_Status_Topic" or not endpoint.type_id:continue
                schema,_=get_types_for_typeid(participant,endpoint.type_id,duration(seconds=4))
                partition=endpoint.qos[Policy.Partition]
                subscriber=Subscriber(participant,qos=Qos(partition) if partition else None)
                reader=DataReader(subscriber,Topic(participant,endpoint.topic_name,schema))
                print("Subscribed read-only E1 status",flush=True)
                break
            time.sleep(.015)
        if reader is None:raise RuntimeError("status publisher unavailable")
        baseline=orientation0=None
        stamp=0;last_write=0.
        while True:
            time.sleep(.02)
            samples=[s for s in reader.take(64) if s.sample_info.valid_data and s.sample_info.source_timestamp>stamp]
            if not samples:continue
            sample=max(samples,key=lambda s:s.sample_info.source_timestamp)
            stamp=sample.sample_info.source_timestamp
            state=dataclasses.asdict(sample)
            motors=state["motorstatearray"]["motorstates"]
            assert len(motors)==24 and [m["motor_id"] for m in motors]==list(range(24))
            q=[motors[i]["pos"] for i in mapping.values()]
            orientation=state["imudata"]["ori"]
            if not all(math.isfinite(x) for x in q+list(orientation)):continue
            if baseline is None:baseline=q.copy();orientation0=list(orientation)
            if time.monotonic()-last_write>=.08:
                save(out/"latest.json",dict(source_ns=str(stamp),names=list(mapping),q=q,ori=orientation,
                     baseline=baseline,baseline_ori=orientation0))
                last_write=time.monotonic()
    finally:participant.__del__()

if __name__=="__main__":main()
