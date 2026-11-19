"""Loopback reader that validates the bounded January commissioning sender."""
import dataclasses,json,math,os,pathlib,sys,time
from cyclonedds.domain import DomainParticipant
from cyclonedds.sub import DataReader
from cyclonedds.topic import Topic
from cyclonedds.qos import Policy,Qos
from january_transport import MotorCmdArray,SetMode
assert [x.split(":")[0].strip() for x in pathlib.Path("/proc/net/dev").read_text().splitlines() if ":" in x]==["lo"]
p=DomainParticipant(0)
motor=DataReader(p,Topic(p,"Motor_Cmd_Topic",MotorCmdArray),qos=Qos(Policy.Reliability.BestEffort,Policy.Durability.Volatile,
 Policy.Liveliness.Automatic(lease_duration=500000000),Policy.Deadline(deadline=2000000),Policy.History.KeepLast(256)))
mode=DataReader(p,Topic(p,"Control_Mode_Topic",SetMode))
baseline=None; count=0; peak=0.; last=0.; modes=[]; seen=False; first=None; finish=None
raised=len(sys.argv)>2 and sys.argv[2]=="raised-drums"
drums=len(sys.argv)>2 and sys.argv[2] in ("drums","raised-drums")
left_absolute_min=right_absolute_min=0.;left_drop=right_drop=0.;raised_seen=False
last_feedback=0.
right_peak=0.;right_last=0.;left_strokes=right_strokes=0;left_active=right_active=False
previous_stamp=None
end=time.monotonic()+(225 if raised else 192)
while time.monotonic()<end:
    matches=motor.get_matched_publications()
    seen=seen or bool(matches)
    for row in mode.take(64):
        if row.sample_info.valid_data:modes.append(row.mode)
    for row in motor.take(256):
        if not row.sample_info.valid_data:continue
        assert row.controlcmd.action==11 and list(row.controlcmd.axes)==[0,0]
        assert 0 <= row.sample_info.source_timestamp - row.timestamp*1000 < 1000
        assert previous_stamp is None or row.timestamp > previous_stamp
        previous_stamp=row.timestamp
        values=[dataclasses.asdict(x) for x in row.motorcmds]
        if raised and time.monotonic()-last_feedback>=.010:
            temporary=pathlib.Path(sys.argv[1]).parent/"feedback.tmp"
            temporary.write_text(json.dumps([values[3]["pos"],values[14]["pos"]]))
            os.replace(temporary,temporary.with_name("feedback.json"))
            last_feedback=time.monotonic()
        assert len(values)==24 and [x["motor_id"] for x in values]==list(range(24))
        if baseline is None:baseline=values;first=time.monotonic()
        for i,m in enumerate(values):
            if i not in ((3,14) if drums else (3,)):assert m==baseline[i]
            for name in ("kp","kd","tau","vel"):assert m[name]==baseline[i][name]
        last=math.degrees(values[3]["pos"]-baseline[3]["pos"])
        assert -90.000001<=last<=.000001
        peak=min(peak,last);count+=1
        if drums:
            right_last=math.degrees(values[14]["pos"]-baseline[14]["pos"])
            assert -(90 if raised else 10)-.000001<=last<=.000001 and -(90 if raised else 10)-.000001<=right_last<=.000001
            if not raised:assert abs(last*right_last)<1e-8
            right_peak=min(right_peak,right_last)
            if raised:
                la,ra=math.degrees(values[3]["pos"]),math.degrees(values[14]["pos"])
                left_absolute_min=min(left_absolute_min,la);right_absolute_min=min(right_absolute_min,ra)
                raised_seen=raised_seen or abs(la+90)<1e-8 and abs(ra+90)<1e-8
                lactive=raised_seen and abs(ra+90)<1e-8 and la>-75
                ractive=raised_seen and abs(la+90)<1e-8 and ra>-75
                if raised_seen and abs(ra+90)<1e-8:left_drop=max(left_drop,la+90)
                if raised_seen and abs(la+90)<1e-8:right_drop=max(right_drop,ra+90)
            else:lactive=last < -5;ractive=right_last < -5
            if lactive and not left_active:left_strokes+=1
            if ractive and not right_active:right_strokes+=1
            left_active=lactive;right_active=ractive
    if seen and not matches and not mode.get_matched_publications():
        finish=time.monotonic();break
    time.sleep(.0005)
assert finish is not None,"DDS writer still alive"
assert modes in ([],[2]),modes
pathlib.Path(sys.argv[1]).write_text(json.dumps({"motor_samples":count,"motor_records_checked":24*count,
 "mode_requests":modes,"elbow_peak_deg":peak,"elbow_final_deg":last,"right_peak_deg":right_peak,
 "right_final_deg":right_last,"left_strokes":left_strokes,"right_strokes":right_strokes,"max_other_target_delta":0,
 "left_absolute_min":left_absolute_min,"right_absolute_min":right_absolute_min,"left_drop":left_drop,"right_drop":right_drop,
 "motor_and_mode_writers_disconnected":True,"seconds_until_disconnect":None if first is None else finish-first},indent=2)+"\n")
