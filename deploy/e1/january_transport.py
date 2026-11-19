"""Bounded January E1 motor transport. Planner commands arrive on stdin."""
import argparse
import dataclasses
import fcntl
import json
import math
import os
import pathlib
import select
import signal
import socket
import struct
import sys
import time
from cyclonedds.domain import DomainParticipant
from cyclonedds.idl import IdlStruct, types as t, annotations as a
from cyclonedds.pub import DataWriter
from cyclonedds.qos import Qos, Policy
from cyclonedds.topic import Topic
from cyclonedds.builtin import BuiltinDataReader, BuiltinTopicDcpsPublication
from cyclonedds.dynamic import get_types_for_typeid
from cyclonedds.util import duration

@a.final
@dataclasses.dataclass
class MotorCmd(IdlStruct, typename="RobotMotorCmd::MotorCmd"):
    pos:t.float64
    vel:t.float64
    tau:t.float64
    kp:t.float64
    kd:t.float64
    motor_id:t.uint16

@a.final
@dataclasses.dataclass
class ControlCmd(IdlStruct, typename="RobotMotorCmd::ControlCmd"):
    axes:t.array[t.float64,2]
    action:t.int32

@a.final
@dataclasses.dataclass
class MotorCmdArray(IdlStruct, typename="RobotMotorCmd::MotorCmdArray"):
    motorcmds:t.sequence[MotorCmd,24]
    controlcmd:ControlCmd
    timestamp:t.int64

@a.final
@dataclasses.dataclass
class SetMode(IdlStruct, typename="RobotSetMode::SetMode"):
    mode:t.uint16

def raised_targets(frame, baseline):
    assert -1<=frame<=8550
    initial=(baseline[3]["pos"],baseline[14]["pos"])
    if frame<0 or frame==8550:return initial
    raised=-math.pi/2
    if frame<=3000:
        blend=(1-math.cos(math.pi*frame/3000))/2
        return tuple(x+(raised-x)*blend for x in initial)
    if frame<3100:return (raised,raised)
    if frame<6300:
        stroke,local=divmod(frame-3100,800)
        drop=math.radians(30)*(1-math.cos(2*math.pi*local/800))/2
        return (raised+drop,raised) if stroke%2==0 else (raised,raised+drop)
    blend=(1-math.cos(math.pi*(frame-6300)/2250))/2
    return tuple(raised+(x-raised)*blend for x in initial)

def validate_frame(row, baseline, previous, stage):
    dual=stage in ("drums","raised-drums")
    assert not row.get("shadow",False), "shadow targets cannot drive live transport"
    assert row["kind"]=="target" and row["stage"]==stage and row["profile"]=="suspended"
    assert row["action"]==11 and row["axes"]==[0,0]
    motors=row["motors"]
    assert len(motors)==24 and [m["motor_id"] for m in motors]==list(range(24))
    assert 0 <= time.time_ns()//1000000-int(row["receipt_ms"]) <= 40
    assert 0 <= time.time_ns()//1000000-int(row["telemetry_receipt_ms"]) <= 40
    assert int(row["telemetry_source_ns"]) > 0
    assert row["sequence"] == (previous["sequence"]+1 if previous else 0)
    for i,m in enumerate(motors):
        assert all(math.isfinite(m[k]) for k in ("pos","vel","tau","kp","kd"))
        assert m["vel"]==m["tau"]==0
        assert m["kp"]==(0 if i==23 else 50)
        assert m["kd"]==(1 if i in (9,10,20,21) else 5)
        movable = (3,14) if dual else (3,)
        if baseline and (i not in movable or stage=="hold"): assert m==baseline[i]
    assert motors[23]["pos"]==0 and -2.44 <= motors[3]["pos"] <=0
    if dual:
        assert all(-math.radians(130)<=motors[slot]["pos"]<=0 for slot in (3,14))
    if stage=="raised-drums":
        frame=row["reference_frame"]
        assert isinstance(frame,int) and -1<=frame<=8550
        if baseline is None:
            assert frame==-1
        else:
            expected=raised_targets(frame,baseline)
            assert all(abs(motors[slot]["pos"]-target)<1e-9 for slot,target in zip((3,14),expected))
        if previous:
            assert 0<=frame-previous["reference_frame"]<=1
    elif baseline:
        peak=10 if stage=="drums" else 90 if stage=="elbow90" else 5
        for slot in ((3,14) if stage=="drums" else (3,)):
            assert -math.radians(peak)-1e-10 <= motors[slot]["pos"]-baseline[slot]["pos"] <=1e-10
            if stage=="drums": assert -math.radians(130)<=motors[slot]["pos"]<=0
        if stage=="drums":
            assert abs((motors[3]["pos"]-baseline[3]["pos"])*(motors[14]["pos"]-baseline[14]["pos"]))<1e-12
    if previous:
        assert int(row["telemetry_source_ns"]) > int(previous["telemetry_source_ns"])
        assert int(row["receipt_ms"]) > int(previous["receipt_ms"])
        peak=30 if stage=="raised-drums" else 10 if stage=="drums" else 90 if stage=="elbow90" else 5
        duration_s=16 if stage=="raised-drums" else 12 if stage=="drums" else 180 if stage=="elbow90" else 15
        max_step=math.radians(peak)*math.pi/duration_s*.020
        for slot in ((3,14) if dual else (3,)):
            assert abs(motors[slot]["pos"]-previous["motors"][slot]["pos"]) <= max_step+1e-10
    return motors

def command_timestamp_ns(row, host_now_ns, domain, previous_ns):
    age_ns = host_now_ns - int(row["telemetry_receipt_ms"]) * 1000000
    assert 0 <= age_ns <= 40000000, "source telemetry expired"
    stamp = host_now_ns if domain == "host" else int(row["telemetry_source_ns"]) + age_ns
    assert previous_ns is None or stamp > previous_ns, "command source clock reversed"
    return stamp

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stage",required=True,choices=("hold","elbow","elbow90","drums","raised-drums"))
    ap.add_argument("--live",action="store_true")
    ap.add_argument("--execute",action="store_true")
    ap.add_argument("--peer-prefix",default="")
    ap.add_argument("--handback-from")
    ap.add_argument("--timestamp-domain", choices=("host", "robot"), default="host")
    ap.add_argument("--ready",required=True)
    ap.add_argument("--receipt",required=True)
    args=ap.parse_args()
    for path in (args.ready,args.receipt):
        assert not pathlib.Path(path).exists(), "output exists"
    interfaces=[x.split(":")[0].strip() for x in pathlib.Path("/proc/net/dev").read_text().splitlines() if ":" in x]
    if args.live:
        assert args.execute and len(args.peer_prefix)==24
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
            reply=fcntl.ioctl(s.fileno(),0x8915,struct.pack("256s",b"eno1"))
            assert socket.inet_ntoa(reply[20:24])=="192.168.55.101"
        if args.stage=="elbow":
            assert args.handback_from, "verified hold receipt required"
            previous=json.loads(pathlib.Path(args.handback_from).read_text())
            assert previous["stage"]=="hold" and previous["result"]=="stage complete"
            assert previous["live"] is True and previous["participant_deleted"] is True
            assert previous["peer_prefix"]==args.peer_prefix
            assert previous.get("operator_confirmed_factory_control") is True
            assert previous.get("hold_session_verified") is True
            assert 0<=time.time()-previous["finished_epoch"]<=600
    else:
        assert interfaces==["lo"], "offline run requires isolated loopback"
    assert MotorCmdArray.__idl__.get_type_id().serialize().hex()=="00070000f2f315417f2fd893ffc1e75f2c4f08"
    assert SetMode.__idl__.get_type_id().serialize().hex()=="00070000f2cc773776cccd5cf6f3ba76cf79c6"
    participant=DomainParticipant(0)
    status_discovered=False
    if args.live:
        discovery=BuiltinDataReader(participant,BuiltinTopicDcpsPublication)
        end=time.monotonic()+8
        while not status_discovered and time.monotonic()<end:
            for ep in discovery.take(64):
                if ep.sample_info.valid_data and ep.topic_name in ("Motor_Cmd_Topic","Control_Mode_Topic"):
                    raise RuntimeError("another command publisher is present")
                if ep.sample_info.valid_data and ep.topic_name=="Robot_Status_Topic" and ep.key.hex[:24]==args.peer_prefix:
                    get_types_for_typeid(participant,ep.type_id,duration(seconds=3))
                    # The independent observer owns the one status subscription.
                    # A second reader makes the wire tap receive duplicate DATA.
                    # Fresh telemetry still reaches this sender via the guarded
                    # planner, checked independently against the host clock.
                    status_discovered=True
                    break
            time.sleep(.01)
        assert status_discovered,"fresh E1 status writer missing"
    motor_topic=Topic(participant,"Motor_Cmd_Topic",MotorCmdArray)
    mode_topic=Topic(participant,"Control_Mode_Topic",SetMode)
    motor=DataWriter(participant,motor_topic,qos=Qos(Policy.Reliability.Reliable(max_blocking_time=10000000),
        Policy.Durability.Volatile,Policy.History.KeepLast(1),
        Policy.Liveliness.Automatic(lease_duration=500000000),Policy.Deadline(deadline=2000000)))
    mode=DataWriter(participant,mode_topic,qos=Qos(Policy.Reliability.Reliable(max_blocking_time=10000000),
        Policy.Durability.TransientLocal,Policy.History.KeepLast(1)))
    # Deleting the complete participant closes both command endpoints.
    modes=0
    count=0
    active=None
    latest=None
    baseline=None
    first_send=None
    last_send=None
    last_command_timestamp=None
    result="startup failed"
    def interrupted(signum, frame):
        raise RuntimeError("operator or supervisor stopped the session")
    signal.signal(signal.SIGTERM,interrupted)
    signal.signal(signal.SIGINT,interrupted)
    try:
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if motor.get_matched_subscriptions() and mode.get_matched_subscriptions():break
            time.sleep(.01)
        for writer in (motor,mode):
            handles=writer.get_matched_subscriptions()
            assert len(handles)==1,"exactly one matching reader required"
            endpoint=writer.get_matched_subscription_data(handles[0])
            if args.live:
                assert endpoint.key.hex[:24]==args.peer_prefix,"unexpected robot reader"
        pathlib.Path(args.ready).write_text(json.dumps({"matched":True,"mode_requests_sent":0,
            "command_owner_prefix":participant.get_guid().hex[:24],"created_epoch":time.time()})+"\n")
        os.set_blocking(sys.stdin.fileno(),False)
        buffer=b""
        last_update=None
        due=time.monotonic()
        startup_deadline=due+12
        while True:
            if args.live:
                for ep in discovery.take(128):
                    if ep.sample_info.valid_data and ep.topic_name in ("Motor_Cmd_Topic","Control_Mode_Topic"):
                        assert ep.key.hex[:24]==participant.get_guid().hex[:24],"competing command publisher"
            ready,_,_=select.select([sys.stdin],[],[],max(0,min(.002,due-time.monotonic())))
            if ready:
                chunk=os.read(sys.stdin.fileno(),65536)
                if not chunk:raise RuntimeError("planner pipe closed")
                buffer+=chunk
                assert len(buffer)<1048576,"planner output overflow"
                while b"\n" in buffer:
                    line,buffer=buffer.split(b"\n",1)
                    row=json.loads(line)
                    if row["kind"]=="stop":
                        result=row["reason"]
                        return
                    motors=validate_frame(row,baseline,latest,args.stage)
                    if baseline is None:baseline=motors
                    latest=row
                    last_update=time.monotonic()
                    active=MotorCmdArray([MotorCmd(**m) for m in motors],ControlCmd([0.,0.],11),0)
            now=time.monotonic()
            if active is None:
                assert now<startup_deadline,"no fresh baseline"
                due=now+.002
                continue
            assert now-last_update<=.04,"planner heartbeat expired"
            assert 0<=time.time_ns()//1000000-int(latest["receipt_ms"])<=40,"telemetry expired"
            assert 0<=time.time_ns()//1000000-int(latest["telemetry_receipt_ms"])<=40,"source telemetry expired"
            if first_send is not None:
                assert now-first_send <= (203.0 if args.stage=="raised-drums" else 1.25 if args.stage=="hold" else 50.0 if args.stage=="drums" else 182.0 if args.stage=="elbow90" else 17.0),"stage time limit"
            if now>=due:
                assert now-due<=.010,"publication deadline missed"
                stamp_ns=command_timestamp_ns(latest,time.time_ns(),args.timestamp_domain,last_command_timestamp)
                active.timestamp=stamp_ns//1000
                motor.write(active,timestamp=stamp_ns)
                last_command_timestamp=stamp_ns
                count+=1
                last_send=now
                if first_send is None:
                    first_send=now
                    mode.write(SetMode(2),timestamp=stamp_ns)
                    modes+=1
                due=now+.002
    except Exception as error:
        result=str(error) or type(error).__name__
        raise
    finally:
        participant.__del__()
        receipt={"stage":args.stage,"profile":"suspended","timestamp_domain":args.timestamp_domain,
            "result":result,"physical_handback_verified":False,
            "operator_confirmed_factory_control":False,"peer_prefix":args.peer_prefix,
            "finished_epoch":time.time(),"action":11,"axes":[0,0],"mode_request":2,
            "mode_requests_sent":modes,"motor_samples_sent":count,"live":args.live,
            "participant_deleted":True,"active_seconds":None if first_send is None else last_send-first_send}
        pathlib.Path(args.receipt).write_text(json.dumps(receipt,indent=2)+"\n")

if __name__=="__main__":
    main()
