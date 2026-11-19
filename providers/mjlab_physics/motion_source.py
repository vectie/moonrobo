"""Inspect upstream mjlab motion files before admitting physics into unified memory."""
import glob
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

import numpy as np


FIELDS = {"joint_pos": 29, "joint_vel": 29, "root_pos_w": 3, "root_quat_w": 4,
          "root_lin_vel_w": 3, "root_ang_vel_w": 3}


def motion_argument(source):
    # train.py expands a comma list in the given order. MotionLoader sorts a glob.
    if "," in source:
        return [str(Path(p.strip()).expanduser()) for p in source.split(",")]
    return str(Path(source).expanduser())


def _sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _validate(shapes):
    frames = shapes["joint_pos"][0]
    if frames < 1 or any(shapes[k] != (frames, w) for k, w in FIELDS.items()):
        raise ValueError(f"incompatible G1 motion shapes: {shapes}")
    return frames


def _npz_shape(archive, key):
    # Read only the NPY header. An unadmitted archive can contain large arrays.
    with archive.open(key + ".npy") as f:
        version = np.lib.format.read_magic(f)
        # For primitive numeric fields, the v2 and v3 headers are ASCII and
        # both use a four-byte header length.
        read = {(1, 0): np.lib.format.read_array_header_1_0,
                (2, 0): np.lib.format.read_array_header_2_0,
                (3, 0): np.lib.format.read_array_header_2_0}
        if version not in read:
            raise ValueError(f"unsupported numeric NPY header {version} for {key}")
        shape, _, dtype = read[version](f)
    if dtype.kind not in "fiu" or dtype.itemsize > 8:
        raise ValueError(f"unsupported motion dtype {dtype} for {key}")
    return shape


def inspect(source):
    arg = motion_argument(source)
    if isinstance(arg, list):
        paths = [Path(p) for p in arg]
    elif glob.has_magic(arg):
        paths = [Path(p) for p in sorted(glob.glob(arg))]
    else:
        paths = [Path(arg)]
    if not paths:
        raise ValueError(f"no matching motion files: {source}")
    content = []
    if len(paths) == 1 and paths[0].is_dir():
        root = paths[0]
        arrays = {k: np.load(root / (k + ".npy"), mmap_mode="r") for k in FIELDS}
        frames = _validate({k: a.shape for k, a in arrays.items()})
        if any(a.dtype.kind not in "fiu" or a.dtype.itemsize > 8 for a in arrays.values()):
            raise ValueError("unsupported packed motion dtype")
        ends = np.load(root / "motion_ends.npy", mmap_mode="r")
        if (ends.ndim != 1 or ends.dtype.kind not in "iu" or not len(ends)
                or ends[0] < 1 or ends[-1] != frames):
            raise ValueError("invalid packed clip boundaries")
        for i in range(1, len(ends), 65536):
            n = min(65536, len(ends) - i)
            if np.any(ends[i:i+n] <= ends[i-1:i+n-1]):
                raise ValueError("nonincreasing packed clip boundaries")
        clips = len(ends)
        extra = max(a.nbytes for a in arrays.values()) + ends.nbytes
        files = [k + ".npy" for k in FIELDS] + ["motion_ends.npy", "joint_names.json"]
        if (root / "motion_names.json").exists():
            files.append("motion_names.json")
        content = [(name, _sha(root / name)) for name in files]
    else:
        frames, extra, clips = 0, 0, len(paths)
        for path in paths:
            with ZipFile(path) as z:
                frames += _validate({k: _npz_shape(z, k) for k in FIELDS})
                z.getinfo("joint_names.npy")
                # The upstream NPZ path materializes every member before joining fields.
                extra += sum(entry.file_size for entry in z.infolist())
            content.append((path.name, _sha(path)))
        extra += 8 * max(FIELDS.values()) * frames
    digest = hashlib.sha256(json.dumps(content, separators=(",", ":")).encode()).hexdigest()
    return dict(manifest_sha256=digest, clips=clips, frames=frames, source_host_bytes=str(extra))
