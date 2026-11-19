"""Decode incoming Atlas E1 status packets from an Ethernet pcap on stdin.

Output is one SDK-ordered status line per DDS sample. The only SDK symbol
called here consumes serialized bytes. This process opens no network socket.
"""
import argparse
import ctypes
import ipaddress
import json
import struct
import sys


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library")
    parser.add_argument("writer_guid", help="32 hex digits from the verified status writer")
    parser.add_argument("--source", default="192.168.55.102")
    parser.add_argument("--destination", default="192.168.55.101")
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
    for arrival, frame in ethernet_packets(sys.stdin.buffer):
        data = rtps_payload(frame, addresses)
        if data is None:
            continue
        for seq, stamp, payload in status_samples(data, writer):
            if decode(0, payload, len(payload), values, len(values), error, len(error)):
                raise ValueError(error.value.decode())
            ids = list(map(int, values[:144:6]))
            if ids != list(range(24)):
                raise ValueError("invalid SDK motor IDs")
            packet = dict(seq=seq, arrival_ns=str(arrival), source_ns=str(stamp),
                          q=values[1:144:6], qd=values[2:144:6], error=list(map(int, values[4:144:6])))
            print(json.dumps(dict(packet=packet, motor_ids=ids), separators=(",", ":"), allow_nan=False), flush=True)


if __name__ == "__main__":
    main()
