"""Stream a verified G1 corpus through the pinned authors' CSV-to-NPZ converter."""
import contextlib
import hashlib
import inspect
import json
import math
import multiprocessing
import os
import tempfile
from pathlib import Path

import numpy as np

from motion_source import FIELDS


def _digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _init_worker(directory, offsets, joint_names):
    global _outputs, _header_offsets, _names, _loader, _quiet
    import torch
    from mjlab.scripts.csv_to_npz import MotionLoader
    torch.set_num_threads(1)
    _loader = MotionLoader
    _outputs = {k: os.open(directory / (k + ".npy"), os.O_WRONLY) for k in FIELDS}
    _header_offsets, _names = offsets, joint_names
    _quiet = open(os.devnull, "w")


def _convert(task):
    path, digest, fps, source_frames, first, n = task
    if _digest(path) != digest:
        raise ValueError(f"canonical CSV hash mismatch: {path}")
    with contextlib.redirect_stdout(_quiet):
        clip = _loader(str(path), fps, 50.0, device="cpu")
        arrays = clip.arrays()
    if clip.input_frames != source_frames or list(arrays["joint_names"]) != _names:
        raise ValueError(f"native joint names or input length changed: {path}")
    for k, width in FIELDS.items():
        x = arrays[k]
        if x.shape != (n, width) or x.dtype != np.float32 or not np.isfinite(x).all():
            raise ValueError(f"invalid original converter output for {path}, {k}")
        payload = memoryview(np.ascontiguousarray(x, dtype="<f4")).cast("B")
        offset = _header_offsets[k] + first * 4 * width
        while payload:
            written = os.pwrite(_outputs[k], payload, offset)
            if written <= 0:
                raise OSError(f"short write for {path}, {k}")
            payload = payload[written:]
            offset += written
    return n


def pack_author_csv(manifest, destination, workers=1):
    """Every numeric field is the unmodified FP32 output of upstream MotionLoader."""
    from mjlab.scripts.csv_to_npz import JOINT_NAMES, MotionLoader
    from mjlab.utils.lab_api.math import quat_slerp
    manifest, destination = Path(manifest), Path(destination)
    if destination.exists():
        raise FileExistsError(destination)
    if workers < 1:
        raise ValueError("workers must be positive")
    raw = manifest.read_bytes()
    catalog = json.loads(raw)
    if catalog["control_dt"] != 0.02 or catalog["quaternion_order"] != "xyzw":
        raise ValueError("expected 50 Hz control and canonical xyzw CSVs")
    names = catalog["splits"]["train"]
    rows = {r["id"]: r for r in catalog["clips"]}
    if not names or len(set(names)) != len(names) or len(rows) != len(catalog["clips"]):
        raise ValueError("empty or duplicate clip identifiers")
    ends, tasks = [], []
    first = 0
    for name in names:
        r = rows[name]
        if r["layout"] != "root_xyz+quaternion_xyzw+g1_29_joint_angles":
            raise ValueError(f"unsupported CSV layout for {name}")
        duration = (r["source_frames"] - 1) * (1.0 / r["fps"])
        n = math.floor(duration / 0.02 + 1e-6) + 1
        tasks.append((manifest.parent / r["path"], r["sha256"], r["fps"], r["source_frames"], first, n))
        first += n
        ends.append(first)
    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        staging = Path(tmp) / "packed"
        staging.mkdir()
        offsets = {}
        for k, width in FIELDS.items():
            with (staging / (k + ".npy")).open("wb") as f:
                np.lib.format.write_array_header_1_0(f, {
                    "descr": "<f4", "fortran_order": False, "shape": (first, width)})
                offsets[k] = f.tell()
                f.truncate(offsets[k] + 4 * first * width)
        ctx = multiprocessing.get_context("spawn")
        with ctx.Pool(workers, _init_worker, (staging, offsets, list(JOINT_NAMES))) as pool:
            converted = 0
            for i, count in enumerate(pool.imap_unordered(_convert, tasks, chunksize=8), 1):
                converted += count
                if i % 2000 == 0 or i == len(names):
                    print(f"author CSV {i}/{len(names)} clips, {converted} frames", flush=True)
        if converted != first:
            raise ValueError("incomplete conversion")
        np.save(staging / "motion_ends.npy", np.asarray(ends, dtype="<i8"))
        (staging / "joint_names.json").write_text(json.dumps(list(JOINT_NAMES)))
        (staging / "motion_names.json").write_text(json.dumps(names))
        fields = {f.name: _digest(f) for f in sorted(staging.iterdir())}
        recipe = dict(source_manifest_sha256=hashlib.sha256(raw).hexdigest(), files=fields,
                      converter_sha256=_digest(Path(inspect.getfile(MotionLoader))),
                      rotation_source_sha256=_digest(Path(inspect.getfile(quat_slerp))))
        key = hashlib.sha256(json.dumps(recipe, sort_keys=True).encode()).hexdigest()
        (staging / "source.json").write_text(json.dumps(dict(
            **recipe, manifest_sha256=key, clips=len(names), frames=first,
            joint_names=list(JOINT_NAMES), control_dt=0.02), indent=2) + "\n")
        os.rename(staging, destination)
