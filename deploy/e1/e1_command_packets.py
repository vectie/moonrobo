"""Offline decoder of this commissioning sender's RTPS command DATA.

Reads an Ethernet capture and exact participant prefix; opens no socket.
Outbound UDP checksums may be incomplete in a host capture because of NIC
offload. This report checks CDR content, not the on-wire checksum offload.
"""
import dataclasses
import ipaddress
import json
import math
import pathlib
import struct
import sys
from e1_status_packets import ethernet_packets, status_samples
from january_transport import MotorCmdArray, SetMode


def main():
    arguments = sys.argv[1:]
    expect_empty = len(arguments) == 4 and arguments[-1] == "--expect-no-commands"
    assert len(arguments) == 3 or expect_empty
    capture, ready_path, output = map(pathlib.Path, arguments[:3])
    assert not output.exists()
    prefix = bytes.fromhex(json.loads(ready_path.read_text())["command_owner_prefix"])
    receipt = json.loads((capture.parent / "transport.json").read_text())
    assert receipt["profile"] == "suspended"
    raised = receipt["stage"] == "raised-drums"
    typing = receipt["stage"] == "typing-elbows"
    drums = receipt["stage"] in ("drums","raised-drums","typing-elbows")
    peak_degrees = 90 if raised else 10 if drums else 90 if receipt["stage"] == "elbow90" else 5
    assert len(prefix) == 12
    addresses = ipaddress.IPv4Address("192.168.55.101").packed + ipaddress.IPv4Address("192.168.55.102").packed
    seen = {}
    baseline = None
    modes = []
    motors = 0
    duplicates = 0
    entities = {}
    first = last = None
    minimum = maximum = final = 0.0
    right_minimum = right_final = 0.0
    left_strokes = right_strokes = 0
    left_active = right_active = False
    left_absolute_min=right_absolute_min=0.0
    left_drop=right_drop=0.0
    raised_seen=False
    with capture.open("rb") as stream:
        for arrival, frame in ethernet_packets(stream):
            if frame[12:14] != b"\x08\x00":
                continue
            ip = frame[14:]
            if ip[12:20] != addresses or ip[9] != 17:
                continue
            header = (ip[0] & 15) * 4
            size = int.from_bytes(ip[2:4], "big")
            assert ip[0] >> 4 == 4 and header >= 20 and header + 8 <= size <= len(ip)
            assert not int.from_bytes(ip[6:8], "big") & 0x3fff
            udp = ip[header:size]
            assert int.from_bytes(udp[4:6], "big") == len(udp)
            data = udp[8:]
            if data[:4] != b"RTPS" or data[8:20] != prefix:
                continue
            offset = 20
            user_writers = set()
            while offset < len(data):
                tag, flags = struct.unpack_from("BB", data, offset)
                endian = "<" if flags & 1 else ">"
                length = struct.unpack_from(endian + "H", data, offset + 2)[0]
                start = offset + 4
                offset = start + length if length else len(data)
                assert offset <= len(data)
                body = data[start:offset]
                if tag in (0x15, 0x16) and len(body) >= 12 and body[11] in (2, 3):
                    user_writers.add(body[8:12])
            for entity in user_writers:
                for sequence, stamp, payload in status_samples(data, prefix + entity):
                    key = (entity, sequence)
                    if key in seen:
                        assert seen[key] == (stamp, payload), "conflicting retransmission"
                        duplicates += 1
                        continue
                    seen[key] = (stamp, payload)
                    if len(payload) < 16:
                        mode = SetMode.deserialize(payload)
                        assert mode.mode == 2
                        modes.append(mode.mode)
                        entities.setdefault(entity.hex(), "mode")
                        assert entities[entity.hex()] == "mode"
                        continue
                    command = MotorCmdArray.deserialize(payload)
                    values = [dataclasses.asdict(m) for m in command.motorcmds]
                    assert len(values) == 24 and [m["motor_id"] for m in values] == list(range(24))
                    assert command.controlcmd.action == 11 and list(command.controlcmd.axes) == [0.0, 0.0]
                    if baseline is None:
                        baseline = values
                        first = arrival
                    for i, motor in enumerate(values):
                        assert all(math.isfinite(motor[k]) for k in ("pos", "vel", "tau", "kp", "kd"))
                        if i not in ((3,14) if drums else (3,)):
                            assert motor == baseline[i], "non-elbow target changed on wire"
                        for field in ("vel", "tau", "kp", "kd"):
                            assert motor[field] == baseline[i][field]
                    final = math.degrees(values[3]["pos"] - baseline[3]["pos"])
                    if not raised and not typing:assert -peak_degrees-.000001 <= final <= .000001
                    minimum, maximum = min(minimum, final), max(maximum, final)
                    if drums:
                        right_final = math.degrees(values[14]["pos"]-baseline[14]["pos"])
                        if not raised and not typing:
                            assert -peak_degrees-.000001<=right_final<=.000001
                            assert abs(final*right_final)<1e-8
                        right_minimum=min(right_minimum,right_final)
                        if typing:
                            for slot,target in ((3,-1.4477981791899937),(14,-0.5434064639344343)):
                                angle=values[slot]["pos"]
                                assert -math.radians(130)<=angle<=0
                                assert min(baseline[slot]["pos"],target)-1e-9<=angle<=max(baseline[slot]["pos"],target)+1e-9
                            left_absolute_min=min(left_absolute_min,math.degrees(values[3]["pos"]))
                            right_absolute_min=min(right_absolute_min,math.degrees(values[14]["pos"]))
                            lactive=ractive=False
                        elif raised:
                            la,ra=math.degrees(values[3]["pos"]),math.degrees(values[14]["pos"])
                            left_absolute_min=min(left_absolute_min,la);right_absolute_min=min(right_absolute_min,ra)
                            assert min(-90,math.degrees(baseline[3]["pos"]))-1e-6<=la<=max(-60,math.degrees(baseline[3]["pos"]))+1e-6
                            assert min(-90,math.degrees(baseline[14]["pos"]))-1e-6<=ra<=max(-60,math.degrees(baseline[14]["pos"]))+1e-6
                            raised_seen=raised_seen or abs(la+90)<1e-8 and abs(ra+90)<1e-8
                            lactive=raised_seen and abs(ra+90)<1e-8 and la>-75
                            ractive=raised_seen and abs(la+90)<1e-8 and ra>-75
                            if raised_seen and abs(ra+90)<1e-8:left_drop=max(left_drop,la+90)
                            if raised_seen and abs(la+90)<1e-8:right_drop=max(right_drop,ra+90)
                        else:lactive=final < -peak_degrees/2;ractive=right_final < -peak_degrees/2
                        if lactive and not left_active:left_strokes+=1
                        if ractive and not right_active:right_strokes+=1
                        left_active=lactive;right_active=ractive
                    last = arrival
                    motors += 1
                    entities.setdefault(entity.hex(), "motor")
                    assert entities[entity.hex()] == "motor"
    if expect_empty:
        assert motors == 0 and modes == [] and entities == {}, "unexpected command DATA"
    else:
        assert motors > 0 and modes == [2] and sorted(entities.values()) == ["mode", "motor"]
    report = {"passed": True, "source": "outbound captured RTPS DATA decoded with exact CDR types",
        "command_owner_prefix": prefix.hex(), "motor_samples": motors,
        "motor_records_checked": motors * 24, "mode_requests": modes,
        "duplicate_retransmissions": duplicates, "writer_entities": entities,
        "duration_ms": None if first is None else (last - first) / 1e6,
        "expected_no_commands": expect_empty,
        "action": None if not motors else 11, "axes": None if not motors else [0, 0],
        "max_fixed_target_change_deg": 0 if motors else None,
        "elbow_min_offset_deg": minimum if motors else None,
        "elbow_max_offset_deg": maximum if motors else None, "elbow_final_offset_deg": final if motors else None,
        "right_min_offset_deg":right_minimum,"right_final_offset_deg":right_final,
        "left_strokes":left_strokes,"right_strokes":right_strokes,
        "left_absolute_min":left_absolute_min,"right_absolute_min":right_absolute_min,
        "left_drop":left_drop,"right_drop":right_drop,
        "physical_handback_verified": False}
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
