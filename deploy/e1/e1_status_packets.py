"""Decode incoming Atlas E1 status packets from an Ethernet pcap on stdin.

Output is one SDK-ordered status line per DDS sample. The only SDK symbol
called here consumes serialized bytes. This process opens no network socket.
"""
import argparse
from collections import OrderedDict
import ctypes
import ipaddress
import json
import math
import os
import pathlib
import queue
import struct
import sys
import threading


class StatusDeduplicator:
    """Deliver each exact RTPS writer sample once, as a DDS reader would.

    Different local reader destinations can receive copies of the same DATA.
    Keep the first kernel receipt; a duplicate never refreshes a sample's age.
    The bounded cache is for identity comparison, not for reordering or filling
    missing sequences. Unknown old samples and conflicting identities fail.
    """

    def __init__(self, capacity=2048):
        if capacity < 1:
            raise ValueError("positive sample cache capacity required")
        self.capacity = capacity
        self.recent = OrderedDict()
        self.latest = None
        self.unique = 0
        self.duplicates = 0

    def accept(self, sequence, source_ns, payload):
        identity = (source_ns, payload)
        if sequence in self.recent:
            if self.recent[sequence] != identity:
                raise ValueError("conflicting duplicate E1 status sample")
            self.duplicates += 1
            return False
        if self.latest is not None and sequence <= self.latest:
            raise ValueError("unknown old E1 status sample")
        self.recent[sequence] = identity
        self.latest = sequence
        self.unique += 1
        if len(self.recent) > self.capacity:
            self.recent.popitem(last=False)
        return True


class MirrorWriter:
    """Best-effort display sink: filesystem latency must not stop telemetry."""

    def __init__(self, directory):
        self.directory = directory
        self.pending = queue.Queue(maxsize=1)
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def offer(self, pose):
        try:
            self.pending.put_nowait(pose)
        except queue.Full:
            pass

    def _run(self):
        while not self.stopped.is_set():
            try:
                pose = self.pending.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                temporary = self.directory / "packet-mirror.tmp"
                temporary.write_text(json.dumps(pose, allow_nan=False, separators=(",", ":")))
                os.replace(temporary, self.directory / "latest.json")
            except (OSError, ValueError) as error:
                print(f"read-only mirror update failed: {error}", file=sys.stderr, flush=True)

    def close(self):
        self.stopped.set()
        self.thread.join(timeout=0.2)


def ethernet_packets(stream):
    header = stream.read(24)
    if len(header) != 24:
        raise ValueError("missing pcap header")
    formats = {
        bytes.fromhex("d4c3b2a1"): ("<", 1000), bytes.fromhex("a1b2c3d4"): (">", 1000),
        bytes.fromhex("4d3cb2a1"): ("<", 1), bytes.fromhex("a1b23c4d"): (">", 1),
    }
    endian, scale = formats[header[:4]]
    major, minor, _, _, _, link = struct.unpack_from(endian + "HHIIII", header, 4)
    if (major, minor, link) != (2, 4, 1):
        raise ValueError("expected Ethernet pcap 2.4")
    while record := stream.read(16):
        sec, fraction, length, original = struct.unpack(endian + "IIII", record)
        if original != length or length > 262144 or fraction * scale >= 10**9:
            raise ValueError("invalid or truncated pcap record")
        frame = stream.read(length)
        if len(frame) != length:
            raise ValueError("incomplete Ethernet frame")
        yield sec * 10**9 + fraction * scale, frame


def rtps_payload(frame, addresses):
    if frame[12:14] != b"\x08\x00":
        return None
    ip = frame[14:]
    if ip[12:20] != addresses or ip[9] != 17:
        return None
    header_size = (ip[0] & 15) * 4
    size = int.from_bytes(ip[2:4], "big")
    if ip[0] >> 4 != 4 or header_size < 20 or not header_size + 8 <= size <= len(ip):
        raise ValueError("invalid IPv4 length")
    if int.from_bytes(ip[6:8], "big") & 0x3fff:
        raise ValueError("fragmented status traffic")
    udp = ip[header_size:size]
    data = udp[8:]
    if data[:4] != b"RTPS":
        return None
    if len(data) < 20 or int.from_bytes(udp[4:6], "big") != len(udp):
        raise ValueError("invalid RTPS datagram")
    # For this recorded E1 link the sender supplies UDP checksums.
    pseudo = addresses + b"\x00\x11" + udp[4:6] + udp
    if len(pseudo) % 2:
        pseudo += b"\x00"
    total = sum(struct.unpack(f"!{len(pseudo)//2}H", pseudo))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    if udp[6:8] == b"\x00\x00" or total != 65535:
        raise ValueError("invalid E1 UDP checksum")
    return data


def status_samples(data, writer):
    if data[8:20] != writer[:12]:
        return
    offset = 20
    stamp = None
    while offset < len(data):
        tag, flags = struct.unpack_from("BB", data, offset)
        endian = "<" if flags & 1 else ">"
        size = struct.unpack_from(endian + "H", data, offset + 2)[0]
        start = offset + 4
        offset = start + size if size else len(data)
        if offset > len(data):
            raise ValueError("invalid RTPS submessage length")
        body = data[start:offset]
        if tag == 9:
            if flags & 2:
                stamp = None
            else:
                sec, frac = struct.unpack(endian + "iI", body)
                stamp = sec * 10**9 + ((frac * 10**9 + (1 << 31)) >> 32)
        if tag in (0x15, 0x16) and body[8:12] == writer[12:]:
            if tag != 0x15 or flags != 5 or len(body) < 20 or stamp is None:
                raise ValueError("unsupported E1 DATA encoding")
            high, low = struct.unpack_from("<iI", body, 12)
            payload_at = 4 + struct.unpack_from("<H", body, 2)[0]
            if payload_at < 20 or payload_at > len(body):
                raise ValueError("invalid E1 payload offset")
            yield (high << 32) + low, stamp, body[payload_at:]


def motor_packet(values, seq, arrival, stamp):
    """Preserve every motor's reported torque alongside raw position/velocity.

    Reported torque is not the factory controller's commanded holding effort.
    A stream of zero values must not be treated as verified zero load.
    """
    ids = list(map(int, values[:144:6]))
    if ids != list(range(24)):
        raise ValueError("invalid SDK motor IDs")
    packet = dict(seq=seq, arrival_ns=str(arrival), source_ns=str(stamp),
                  q=list(values[1:144:6]), qd=list(values[2:144:6]),
                  tau=list(values[3:144:6]), error=list(map(int, values[4:144:6])))
    if not all(math.isfinite(x) for name in ("q", "qd", "tau") for x in packet[name]):
        raise ValueError("nonfinite motor telemetry")
    return ids, packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library")
    parser.add_argument("writer_guid", help="32 hex digits from the verified status writer")
    parser.add_argument("--source", default="192.168.55.102")
    parser.add_argument("--destination", default="192.168.55.101")
    parser.add_argument("--mirror-dir", help="update the local read-only pose relay from decoded packets")
    args = parser.parse_args()
    writer = bytes.fromhex(args.writer_guid)
    if len(writer) != 16:
        parser.error("writer GUID must be 16 bytes")
    addresses = b"".join(ipaddress.IPv4Address(a).packed for a in (args.source, args.destination))
    decode = ctypes.CDLL(args.library).moonrobo_e1_status_decode
    decode.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_size_t,
                       ctypes.POINTER(ctypes.c_double), ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    decode.restype = ctypes.c_int
    values = (ctypes.c_double * 171)()
    error = ctypes.create_string_buffer(512)
    mirror_dir = pathlib.Path(args.mirror_dir) if args.mirror_dir else None
    if mirror_dir:
        joint_map = json.loads((mirror_dir / "joint-map.json").read_text())
        assert len(joint_map) == 23 and set(joint_map.values()) == set(range(23))
    mirror = MirrorWriter(mirror_dir) if mirror_dir else None
    baseline = baseline_ori = None
    last_mirror = 0
    samples = StatusDeduplicator()
    for arrival, frame in ethernet_packets(sys.stdin.buffer):
        data = rtps_payload(frame, addresses)
        if data is None:
            continue
        for seq, stamp, payload in status_samples(data, writer):
            if not samples.accept(seq, stamp, payload):
                continue
            if decode(0, payload, len(payload), values, len(values), error, len(error)):
                raise ValueError(error.value.decode())
            ids, packet = motor_packet(values, seq, arrival, stamp)
            if mirror_dir and arrival - last_mirror >= 80000000:
                positions = [packet["q"][slot] for slot in joint_map.values()]
                orientation = list(values[144:148])
                if all(math.isfinite(v) for v in positions + orientation):
                    if baseline is None:
                        baseline, baseline_ori = positions.copy(), orientation.copy()
                    pose = dict(source_ns=str(stamp), names=list(joint_map), q=positions,
                                ori=orientation, baseline=baseline, baseline_ori=baseline_ori)
                    mirror.offer(pose)
                    last_mirror = arrival
            print(json.dumps(dict(packet=packet, motor_ids=ids,
                                  orientation=list(values[144:148]),
                                  angular_velocity=list(values[148:151])),
                             separators=(",", ":"), allow_nan=False), flush=True)
    if mirror:
        mirror.close()
    print(json.dumps(dict(status_unique_samples=samples.unique,
                          exact_duplicate_samples=samples.duplicates)),
          file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
