"""Read MoonRobo's verified 50 Hz G1 shards into mjlab's packed NumPy format."""
import hashlib
import json
import os
from pathlib import Path
import tempfile

import numpy as np
from scipy.spatial.transform import Rotation


def pack(manifest, cache, destination, source_joints, target_joints):
    manifest, cache, destination = map(Path, (manifest, cache, destination))
    if destination.exists():
        raise FileExistsError(destination)
    if len(set(source_joints)) != 29 or sorted(source_joints) != sorted(target_joints):
        raise ValueError("incompatible joint names")
    index = [source_joints.index(j) for j in target_joints]
    catalog = json.loads(manifest.read_bytes())
    if catalog["control_dt"] != 0.02:
        raise ValueError("expected 50 Hz motion data")
    lookup = {r["id"]: r for r in catalog["clips"]}
    names = catalog["splits"]["train"]
    if len(names) != len(set(names)) or not names:
        raise ValueError("empty or duplicate clips")
    configs, ends = [], []
    for name in names:
        row = lookup[name]
        key = hashlib.sha256(f"moonrobo.motion-shard.f64le.v1:{row['sha256']}:{row['fps']:g}".encode()).hexdigest()
        raw = cache / key[:2] / (key + ".f64")
        meta = json.loads(raw.with_suffix(".f64.json").read_bytes())
        if (meta["format"] != "moonrobo.motion-shard.f64le.v1" or
                meta["source_sha256"] != row["sha256"] or meta["source_fps"] != row["fps"] or
                meta["source_frames"] != row["source_frames"] or raw.stat().st_size != meta["frames"] * 608):
            raise ValueError(f"shard mismatch for {name}")
        configs.append((raw, meta["state_sha256"]))
        ends.append((ends[-1] if ends else 0) + meta["frames"])
    # Stream through one clip at a time. Write contiguous per-field payloads so a
    # memory-mapped writer cannot accumulate dirty pages in the process RSS.
    dims = {"root_pos_w": 3, "root_quat_w": 4, "root_lin_vel_w": 3,
            "root_ang_vel_w": 3, "joint_pos": 29, "joint_vel": 29}
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        staging = Path(tmp) / "packed"
        staging.mkdir()
        from contextlib import ExitStack
        with ExitStack() as stack:
            files = {}
            for key, dim in dims.items():
                fd = stack.enter_context((staging / (key + ".npy")).open("wb"))
                np.lib.format.write_array_header_1_0(fd, {"descr": "<f4", "fortran_order": False,
                                                         "shape": (ends[-1], dim)})
                files[key] = fd
            for i, (path, digest) in enumerate(configs):
                data = path.read_bytes()
                if hashlib.sha256(data).hexdigest() != digest:
                    raise ValueError(f"state hash mismatch: {names[i]}")
                frame = np.frombuffer(data, dtype="<f8").reshape(-1, 76)
                quat = Rotation.from_matrix(frame[:, 3:12].reshape(-1, 3, 3)).as_quat()[:, [3, 0, 1, 2]]
                fields = (frame[:, :3], quat, frame[:, 12:15], frame[:, 15:18],
                          frame[:, 18:47][:, index], frame[:, 47:76][:, index])
                for fd, x in zip(files.values(), fields, strict=True):
                    fd.write(np.asarray(x, dtype="<f4", order="C").tobytes())
                if (i + 1) % 20000 == 0:
                    print(f"verified and packed {i+1}/{len(names)} clips", flush=True)
        np.save(staging / "motion_ends.npy", np.array(ends, dtype="<i8"))
        (staging / "joint_names.json").write_text(json.dumps(target_joints))
        (staging / "motion_names.json").write_text(json.dumps(names))
        (staging / "source.json").write_text(json.dumps(dict(
            manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
            clips=len(ends), frames=ends[-1], joint_names=target_joints, control_dt=0.02)))
        os.rename(staging, destination)
