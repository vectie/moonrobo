"""Real G1 references resampled to 50 Hz, with FK of tracked bodies.

Adapted from smc (MIT, Copyright 2026 ETH Zurich, Chong Zhang; see SMC_LICENSE).
The manifest format also accepts externally acquired G1-retargeted motion
catalogs; it does not claim access to or provide a retargeter for BONES-SEED.
"""

from __future__ import annotations

import glob
import os
import hashlib
import json
import io
import itertools
import tempfile
import fcntl
import shutil
from pathlib import Path

import numpy as np
import torch

from .kinematics import G1Kinematics
from .rotations import mat_to_6d, quat_slerp, quat_to_mat, so3_log, yaw_mat

CONTROL_DT = 0.02
BIN_FRAMES = 50  # 1 s bins for return-based reset sampling


def _file_sha256(path: str | Path) -> str:
    with open(path, "rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class _MappedField:
    """Bounded gather from a host memmap; never materialize a whole reference field."""

    def __init__(self, motion, name: str, shape: tuple[int, ...]):
        self.motion, self.name, self.shape = motion, name, shape

    def __getitem__(self, index):
        return self.motion._mapped_field(self.name, index)


class _FrameIndex:
    """Compute clip/bin IDs from clip boundaries without per-frame int64 arrays."""

    def __init__(self, motion, kind: str):
        self.motion, self.kind = motion, kind

    def __getitem__(self, index):
        m = self.motion
        index = torch.as_tensor(index, device=m.device, dtype=torch.long)
        clip = torch.searchsorted(m.clip_start[1:], index, right=True)
        if self.kind == "clip":
            return clip
        candidate = m.clip_bin_start[clip] + torch.div(index - m.clip_start[clip], BIN_FRAMES, rounding_mode="floor")
        return torch.minimum(candidate, m.clip_bin_start[clip + 1] - 1)


class MotionLib:
    def __init__(self, files: list[str], kin: G1Kinematics, device: str, src_fps: float = 30.0,
                 *, compute_body_features: bool = True, storage: str = "eager",
                 cache_dir: str | None = None, max_gather_frames: int = 131072,
                 source_sha256: list[str] | None = None,
                 names: list[str] | None = None):
        if not files:
            raise ValueError("motion library requires real motion files")
        if not np.isfinite(src_fps) or src_fps <= 0:
            raise ValueError("source FPS must be positive and finite")
        self.device = device
        self.names = (list(names) if names is not None else
                      [os.path.splitext(os.path.basename(f))[0] for f in files])
        if len(self.names) != len(files):
            raise ValueError("one clip identifier required per motion file")
        if len(set(self.names)) != len(self.names):
            raise ValueError("clip identifiers must be unique")
        self.files = list(files)
        self.source_fps = float(src_fps)
        self.source_sha256 = source_sha256 or [_file_sha256(f) for f in files]
        if len(self.source_sha256) != len(files):
            raise ValueError("one source SHA256 required per motion file")
        self.manifest = None
        if storage not in ("eager", "mmap"):
            raise ValueError("motion storage must be eager or mmap")
        if max_gather_frames <= 0:
            raise ValueError("max_gather_frames must be positive")
        self.storage = storage
        if storage == "mmap":
            if cache_dir is None:
                raise ValueError("mmap motion storage requires an explicit cache_dir")
            self._init_mmap(kin, Path(cache_dir), compute_body_features, max_gather_frames)
            return
        ps, qs, js = [], [], []
        lens = []
        for f in files:
            raw = torch.tensor(np.loadtxt(f, delimiter=","), dtype=torch.float32)
            if raw.ndim != 2 or raw.shape[0] < 2 or raw.shape[1] != 36:
                raise ValueError(f"{f}: expected >=2 frames of 36-column G1 CSV")
            if not torch.isfinite(raw).all():
                raise ValueError(f"{f}: nonfinite motion data")
            p, q_xyzw, j = raw[:, :3], raw[:, 3:7], raw[:, 7:36]
            quat = torch.cat((q_xyzw[:, 3:4], q_xyzw[:, :3]), -1)
            norm = quat.norm(dim=-1, keepdim=True)
            if (norm < 1e-6).any():
                raise ValueError(f"{f}: invalid root quaternion")
            # Match smc's interpolation order: slerp normalizes its result.
            # Pre-normalizing rounded CSV inputs changes the interpolation
            # weights and therefore reference angular velocities.
            # resample to 50 Hz
            T_src = raw.shape[0]
            dur = (T_src - 1) / src_fps
            n = int(np.floor(dur / CONTROL_DT)) + 1
            if n < 2:
                raise ValueError(f"{f}: clip shorter than one control transition")
            t = torch.arange(n, dtype=torch.float32) * CONTROL_DT * src_fps
            i0 = torch.clamp(t.floor().long(), max=T_src - 2)
            a = (t - i0.float()).clamp(0, 1)
            p = p[i0] * (1 - a[:, None]) + p[i0 + 1] * a[:, None]
            j = j[i0] * (1 - a[:, None]) + j[i0 + 1] * a[:, None]
            quat = quat_slerp(quat[i0], quat[i0 + 1], a)
            ps.append(p), qs.append(quat), js.append(j)
            lens.append(n)
        self.clip_len = torch.tensor(lens, device=device)
        self.clip_start = torch.cumsum(torch.cat((torch.zeros(1, dtype=torch.long), torch.tensor(lens[:-1], dtype=torch.long))), 0).to(device)  # dtype: one clip gives an empty (float) tensor
        self.clip_end = self.clip_start + self.clip_len - 1  # last valid frame (inclusive)
        self.num_frames = int(sum(lens))
        self.clip_id = torch.cat([torch.full((n,), i, dtype=torch.long) for i, n in enumerate(lens)]).to(device)

        root_p, root_R, root_v, root_w, jq, jqd = [], [], [], [], [], []
        for p, quat, j in zip(ps, qs, js):
            R = quat_to_mat(quat)
            v = _gradient(p, CONTROL_DT)
            qd = _gradient(j, CONTROL_DT)
            # angular velocity (world) by central differences of rotations
            w = torch.zeros_like(p)
            w[1:-1] = so3_log(R[2:] @ R[:-2].transpose(-1, -2)) / (2 * CONTROL_DT)
            w[0] = so3_log(R[1] @ R[0].T) / CONTROL_DT
            w[-1] = so3_log(R[-1] @ R[-2].T) / CONTROL_DT
            root_p.append(p), root_R.append(R), root_v.append(v), root_w.append(w), jq.append(j), jqd.append(qd)
        cat = lambda xs: torch.cat(xs).to(device)  # noqa: E731
        self.root_p, self.root_R, self.root_v, self.root_w = cat(root_p), cat(root_R), cat(root_v), cat(root_w)
        self.q, self.qd = cat(jq), cat(jqd)
        del ps, qs, js, root_p, root_R, root_v, root_w, jq, jqd
        self.body_p = self.body_R = self.body_v = self.body_w = None
        # Replay export only reconstructs root/joint observations and preview
        # goals. Training/reward/evaluation retain the default full FK cache.
        with torch.no_grad():
            # Write each FK chunk directly into final storage. Concatenating
            # four full-corpus lists otherwise briefly doubles ~450 MB here.
            body_fields = None
            chunk_size = 8192 if str(device).startswith("cpu") else 65536
            for s in range(0, self.num_frames if compute_body_features else 0, chunk_size):
                e = min(s + chunk_size, self.num_frames)
                out = kin.forward(self.root_p[s:e], self.root_R[s:e], self.root_v[s:e], self.root_w[s:e], self.q[s:e], self.qd[s:e])
                if body_fields is None:
                    body_fields = [value.new_empty((self.num_frames,) + value.shape[1:]) for value in out]
                for storage, value in zip(body_fields, out):
                    storage[s:e] = value
            if compute_body_features:
                self.body_p, self.body_R, self.body_v, self.body_w = body_fields
        # per-frame static goal parts: q, qd, root velocities in the root frame
        Rt = self.root_R.transpose(-1, -2)
        self.root_v_local = (Rt @ self.root_v.unsqueeze(-1)).squeeze(-1)
        self.root_w_local = (Rt @ self.root_w.unsqueeze(-1)).squeeze(-1)
        self.root_gz = self.root_R[:, 2, 2]  # -(projected gravity z) of the reference root: g_b = R^T (0,0,-1)
        # 1 s bins
        bin_clip, bin_start = [], []
        for c in range(len(lens)):
            # A reset must have a next state. Do not create a terminal-only bin
            # when length % BIN_FRAMES == 1 (smc's last-bin corner case).
            nb = int(np.ceil((lens[c] - 1) / BIN_FRAMES))
            for b in range(nb):
                bin_clip.append(c)
                bin_start.append(int(self.clip_start[c]) + b * BIN_FRAMES)
        self.bin_clip = torch.tensor(bin_clip, device=device)
        self.bin_start = torch.tensor(bin_start, device=device)
        self.num_bins = len(bin_start)
        self.frame_bin = torch.zeros(self.num_frames, dtype=torch.long, device=device)
        for b in range(self.num_bins):
            c = bin_clip[b]
            s = bin_start[b]
            e = min(s + BIN_FRAMES, int(self.clip_end[c]) + 1)
            self.frame_bin[s:e] = b
            if e == int(self.clip_end[c]):
                self.frame_bin[e] = b

    @staticmethod
    def from_dir(path: str, kin: G1Kinematics, device: str,
                 *, compute_body_features: bool = True, storage: str = "eager",
                 cache_dir: str | None = None, max_gather_frames: int = 131072) -> MotionLib:
        files = sorted(glob.glob(os.path.join(path, "*.csv")))
        return MotionLib(files, kin, device, compute_body_features=compute_body_features,
                         storage=storage, cache_dir=cache_dir, max_gather_frames=max_gather_frames)

    @staticmethod
    def from_manifest(path: str, kin: G1Kinematics, device: str,
                      split: str = "train", *, compute_body_features: bool = True,
                      storage: str = "eager", cache_dir: str | None = None,
                      max_gather_frames: int = 131072) -> MotionLib:
        """Load hash-verified G1 CSV clips and an explicit train/eval split.

        External catalog providers must already supply 29-DoF G1 retargets in
        the declared layout, with a common source FPS; raw human poses are not
        silently treated as G1 joints. Split identities remain in provenance.
        """
        path = Path(path)
        manifest = json.loads(path.read_text())
        if manifest.get("format") != "moonrobo.aligned-motion-catalog.v1":
            raise ValueError("unsupported motion manifest")
        if manifest.get("quaternion_order") != "xyzw":
            raise ValueError("G1 CSV requires root quaternion xyzw")
        rows = manifest["clips"]
        by_id = {row["id"]: row for row in rows}
        if len(by_id) != len(rows):
            raise ValueError("duplicate manifest clip identifiers")
        selected = manifest["splits"][split]
        if len(selected) != len(set(selected)):
            raise ValueError("duplicate split clip identifiers")
        files, hashes = [], []
        fps = float(manifest["source_fps"])
        for name in selected:
            row = by_id[name]
            if row.get("layout") != "root_xyz+quaternion_xyzw+g1_29_joint_angles":
                raise ValueError("motion catalog requires already retargeted G1 CSV")
            if float(row.get("fps", fps)) != fps:
                raise ValueError("all clips must share declared source FPS")
            filename = path.parent / row["path"]
            if _file_sha256(filename) != row["sha256"]:
                raise ValueError(f"motion SHA256 mismatch: {name}")
            files.append(str(filename))
            hashes.append(row["sha256"])
        result = MotionLib(files, kin, device, src_fps=fps,
                           compute_body_features=compute_body_features, storage=storage,
                           cache_dir=cache_dir, max_gather_frames=max_gather_frames,
                           source_sha256=hashes, names=list(selected))
        result.manifest = manifest
        result.manifest_path = str(path.resolve())
        result.manifest_sha256 = _file_sha256(path)
        result.split = split
        return result

    def _init_mmap(self, kin: G1Kinematics, cache_dir: Path,
                   compute_body_features: bool, max_gather_frames: int) -> None:
        """Stage bounded CSV chunks to disk and keep reference arrays off the GPU.

        The cache has 76 float32 values per 50 Hz frame (304 bytes). Body FK is
        computed only for the selected batch; no full-corpus body arrays or
        frame-to-clip lookup arrays are allocated. Cache creation is serialized
        across local ranks and a metadata file is published only after flush.
        """
        self._kin = kin
        self.max_gather_frames = max_gather_frames
        cache_dir.mkdir(parents=True, exist_ok=True)
        source_lengths = []
        for filename in self.files:
            with open(filename, "rb") as stream:
                count = sum(bool(line.strip()) and not line.lstrip().startswith(b"#") for line in stream)
            if count < 2:
                raise ValueError(f"{filename}: expected at least two source frames")
            source_lengths.append(count)
        lens = [int(np.floor(((n - 1) / self.source_fps) / CONTROL_DT)) + 1 for n in source_lengths]
        if any(n < 2 for n in lens):
            raise ValueError("motion clip shorter than one control transition")
        self.num_frames = int(sum(lens))
        spec = dict(format="moonrobo.mapped-motion.v1", files=self.names,
                    source_sha256=self.source_sha256, source_lengths=source_lengths,
                    source_fps=self.source_fps, control_dt=CONTROL_DT, shape=[self.num_frames, 76])
        digest = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()[:24]
        data_path = cache_dir / f"motion-{digest}.f32"
        meta_path = cache_dir / f"motion-{digest}.json"
        lock_path = cache_dir / f"motion-{digest}.lock"
        with open(lock_path, "a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            complete = (data_path.is_file() and meta_path.is_file() and
                        data_path.stat().st_size == self.num_frames * 76 * 4 and
                        json.loads(meta_path.read_text()) == spec)
            if not complete:
                # The temporary raw map holds only one source clip at a time.
                required = self.num_frames * 76 * 4 + max(source_lengths) * 36 * 4
                if shutil.disk_usage(cache_dir).free < int(required * 1.1):
                    raise OSError(f"motion cache requires at least {required / 2**30:.1f} GiB free disk plus 10% headroom")
                temporary = cache_dir / f"motion-{digest}.building.f32"
                mapped = np.memmap(temporary, dtype=np.float32, mode="w+", shape=(self.num_frames, 76))
                try:
                    base = 0
                    for filename, source_n, n, expected_hash in zip(
                            self.files, source_lengths, lens, self.source_sha256):
                        self._stage_clip(filename, source_n, n, mapped, base, cache_dir, expected_hash)
                        base += n
                    mapped.flush()
                    del mapped
                    os.replace(temporary, data_path)
                    meta_tmp = meta_path.with_suffix(".building.json")
                    meta_tmp.write_text(json.dumps(spec, sort_keys=True))
                    os.replace(meta_tmp, meta_path)
                finally:
                    if temporary.exists():
                        temporary.unlink()
            fcntl.flock(lock, fcntl.LOCK_UN)
        self._mapped = np.memmap(data_path, dtype=np.float32, mode="r", shape=(self.num_frames, 76))
        self.cache_path = str(data_path)
        self.clip_len = torch.tensor(lens, dtype=torch.long, device=self.device)
        starts = np.cumsum(np.array([0] + lens[:-1], dtype=np.int64))
        self.clip_start = torch.as_tensor(starts.copy(), dtype=torch.long, device=self.device)
        self.clip_end = self.clip_start + self.clip_len - 1
        self.clip_id = _FrameIndex(self, "clip")
        self.frame_bin = _FrameIndex(self, "bin")
        bin_counts = [(n - 2) // BIN_FRAMES + 1 for n in lens]
        bin_offsets = np.cumsum(np.array([0] + bin_counts, dtype=np.int64))
        self.clip_bin_start = torch.as_tensor(bin_offsets.copy(), dtype=torch.long, device=self.device)
        self.num_bins = int(bin_offsets[-1])
        bin_clip = np.repeat(np.arange(len(lens), dtype=np.int64), np.asarray(bin_counts, dtype=np.int64))
        bin_start = starts[bin_clip] + (np.arange(self.num_bins, dtype=np.int64) - bin_offsets[bin_clip]) * BIN_FRAMES
        self.bin_clip = torch.from_numpy(bin_clip).to(self.device)
        self.bin_start = torch.from_numpy(bin_start).to(self.device)
        for field, shape in (("root_p", (3,)), ("root_R", (3, 3)), ("root_v", (3,)),
                             ("root_w", (3,)), ("q", (29,)), ("qd", (29,)),
                             ("root_v_local", (3,)), ("root_w_local", (3,)), ("root_gz", ())):
            setattr(self, field, _MappedField(self, field, (self.num_frames,) + shape))
        self.body_p = self.body_R = self.body_v = self.body_w = None
        if compute_body_features:
            body_count = len(kin.tracked_idx)
            for field, shape in (("body_p", (body_count, 3)), ("body_R", (body_count, 3, 3)),
                                 ("body_v", (body_count, 3)), ("body_w", (body_count, 3))):
                setattr(self, field, _MappedField(self, field, (self.num_frames,) + shape))

    def _stage_clip(self, filename: str, source_n: int, n: int, mapped: np.memmap,
                    base: int, cache_dir: Path, expected_hash: str) -> None:
        with tempfile.NamedTemporaryFile(prefix="motion-source-", suffix=".f32",
                                         dir=cache_dir, delete=False) as temp:
            raw_path = Path(temp.name)
        try:
            raw = np.memmap(raw_path, dtype=np.float32, mode="w+", shape=(source_n, 36))
            offset = 0
            sha = hashlib.sha256()
            with open(filename, "rb") as stream:
                def source_rows():
                    for line in stream:
                        sha.update(line)
                        if line.strip() and not line.lstrip().startswith(b"#"):
                            yield line

                rows = source_rows()
                while chunk_lines := list(itertools.islice(rows, 8192)):
                    chunk = np.loadtxt(io.BytesIO(b"".join(chunk_lines)), delimiter=",",
                                       dtype=np.float64, ndmin=2)
                    if chunk.shape[1] != 36 or not np.isfinite(chunk).all():
                        raise ValueError(f"{filename}: expected finite 36-column G1 CSV")
                    chunk = chunk.astype(np.float32)
                    if not np.isfinite(chunk).all():
                        raise ValueError(f"{filename}: values exceed float32 range")
                    qnorm = np.linalg.norm(chunk[:, 3:7], axis=1)
                    if (qnorm < 1e-6).any():
                        raise ValueError(f"{filename}: invalid root quaternion")
                    raw[offset:offset + len(chunk)] = chunk
                    offset += len(chunk)
            if sha.hexdigest() != expected_hash:
                raise ValueError(f"{filename}: source changed while staging")
            if offset != source_n:
                raise ValueError(f"{filename}: source frame count changed while staging")
            raw.flush()
            for s in range(0, n, 8192):
                e = min(s + 8192, n)
                t = torch.arange(s, e, dtype=torch.float32) * CONTROL_DT * self.source_fps
                i0 = torch.clamp(t.floor().long(), max=source_n - 2)
                a = (t - i0.float()).clamp(0, 1)
                pair = torch.from_numpy(np.array(raw[i0.numpy()], copy=True))
                pair1 = torch.from_numpy(np.array(raw[(i0 + 1).numpy()], copy=True))
                p = pair[:, :3] * (1 - a[:, None]) + pair1[:, :3] * a[:, None]
                j = pair[:, 7:36] * (1 - a[:, None]) + pair1[:, 7:36] * a[:, None]
                q0 = torch.cat((pair[:, 6:7], pair[:, 3:6]), -1)
                q1 = torch.cat((pair1[:, 6:7], pair1[:, 3:6]), -1)
                R = quat_to_mat(quat_slerp(q0, q1, a))
                mapped[base + s:base + e, 0:3] = p.numpy()
                mapped[base + s:base + e, 3:12] = R.reshape(-1, 9).numpy()
                mapped[base + s:base + e, 18:47] = j.numpy()
            del raw
            # Central differences need one halo frame on each side of a chunk.
            for s in range(0, n, 8192):
                e = min(s + 8192, n)
                lo, hi = max(0, s - 1), min(n, e + 1)
                source = np.array(mapped[base + lo:base + hi], copy=True)
                p = torch.from_numpy(source[:, 0:3])
                R = torch.from_numpy(source[:, 3:12].reshape(-1, 3, 3))
                j = torch.from_numpy(source[:, 18:47])
                v, qd = _gradient(p, CONTROL_DT), _gradient(j, CONTROL_DT)
                w = torch.zeros_like(p)
                w[1:-1] = so3_log(R[2:] @ R[:-2].transpose(-1, -2)) / (2 * CONTROL_DT)
                w[0] = so3_log(R[1] @ R[0].T) / CONTROL_DT
                w[-1] = so3_log(R[-1] @ R[-2].T) / CONTROL_DT
                core = slice(s - lo, e - lo)
                mapped[base + s:base + e, 12:15] = v[core].numpy()
                mapped[base + s:base + e, 15:18] = w[core].numpy()
                mapped[base + s:base + e, 47:76] = qd[core].numpy()
        finally:
            raw_path.unlink(missing_ok=True)

    def _mapped_field(self, field: str, index):
        columns = {"root_p": (0, 3), "root_R": (3, 12), "root_v": (12, 15),
                   "root_w": (15, 18), "q": (18, 47), "qd": (47, 76)}
        if isinstance(index, tuple):
            frame_index, trailing = index[0], index[1:]
        else:
            frame_index, trailing = index, ()
        if isinstance(frame_index, torch.Tensor):
            if frame_index.numel() > self.max_gather_frames:
                raise MemoryError("reference gather exceeds max_gather_frames")
            frame_index = frame_index.detach().cpu().numpy()
        elif isinstance(frame_index, slice):
            if len(range(*frame_index.indices(self.num_frames))) > self.max_gather_frames:
                raise MemoryError("reference slice exceeds max_gather_frames")
        elif np.asarray(frame_index).size > self.max_gather_frames:
            raise MemoryError("reference gather exceeds max_gather_frames")
        if field in columns:
            lo, hi = columns[field]
            arr = np.array(self._mapped[frame_index, lo:hi], copy=True)
            tensor = torch.from_numpy(arr).to(self.device)
            if field == "root_R":
                tensor = tensor.reshape(tensor.shape[:-1] + (3, 3))
        elif field in ("root_v_local", "root_w_local", "root_gz"):
            R = self._mapped_field("root_R", frame_index)
            if field == "root_gz":
                tensor = R[..., 2, 2]
            else:
                v = self._mapped_field("root_v" if field == "root_v_local" else "root_w", frame_index)
                tensor = (R.transpose(-1, -2) @ v.unsqueeze(-1)).squeeze(-1)
        else:
            tensor = self.body_state(frame_index)[{"body_p": 0, "body_R": 1,
                                                    "body_v": 2, "body_w": 3}[field]]
        return tensor[(Ellipsis,) + trailing] if trailing else tensor

    def body_state(self, f):
        """Reference FK for one bounded batch, shared across reward/critic terms."""
        if self.storage == "eager":
            return self.body_p[f], self.body_R[f], self.body_v[f], self.body_w[f]
        with torch.no_grad():
            return self._kin.forward(*self.ref_state(f))

    def future_frames(self, f: torch.Tensor, K: int) -> torch.Tensor:
        """Frames f+1..f+K clamped to the clip's last frame, shape (B, K)."""
        end = self.clip_end[self.clip_id[f]]
        fut = f.unsqueeze(-1) + torch.arange(1, K + 1, device=f.device)
        return torch.minimum(fut, end.unsqueeze(-1))

    def goal(self, f: torch.Tensor, K: int) -> torch.Tensor:
        """Goal features from the reference only: K future frames relative to the current reference frame."""
        fut = self.future_frames(f, K)  # (B,K)
        H = yaw_mat(self.root_R[f])  # (B,3,3)
        Ht = H.transpose(-1, -2).unsqueeze(1)
        dp = (Ht @ (self.root_p[fut] - self.root_p[f].unsqueeze(1)).unsqueeze(-1)).squeeze(-1)
        rot = mat_to_6d(Ht @ self.root_R[fut])
        feats = torch.cat(
            (dp, rot, self.root_v_local[fut], self.root_w_local[fut], self.q[fut], self.qd[fut] * 0.1), -1
        )  # (B,K,73)
        return feats.reshape(f.shape[0], -1)

    def ref_state(self, f: torch.Tensor):
        return self.root_p[f], self.root_R[f], self.root_v[f], self.root_w[f], self.q[f], self.qd[f]


def _gradient(x: torch.Tensor, dt: float) -> torch.Tensor:
    g = torch.zeros_like(x)
    g[1:-1] = (x[2:] - x[:-2]) / (2 * dt)
    g[0] = (x[1] - x[0]) / dt
    g[-1] = (x[-1] - x[-2]) / dt
    return g


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Verify and characterize a real G1 motion catalog")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--report", required=True)
    parser.add_argument("--storage", choices=("eager", "mmap"), default="eager")
    parser.add_argument("--cache-dir", default=None)
    args = parser.parse_args()
    torch.set_num_threads(2)
    kin = G1Kinematics(args.device, mjcf_path=args.model)
    motion = MotionLib.from_manifest(args.manifest, kin, args.device,
                                     storage=args.storage, cache_dir=args.cache_dir)
    root_height_min, root_height_max, upright_min = float("inf"), -float("inf"), float("inf")
    for start in range(0, motion.num_frames, 8192):
        frame = torch.arange(start, min(start + 8192, motion.num_frames), device=args.device)
        fields = motion.ref_state(frame) + motion.body_state(frame)
        if not all(bool(torch.isfinite(value).all()) for value in fields):
            raise ValueError("nonfinite resampled kinematics")
        root_height_min = min(root_height_min, float(fields[0][:, 2].min()))
        root_height_max = max(root_height_max, float(fields[0][:, 2].max()))
        upright_min = min(upright_min, float(fields[1][:, 2, 2].min()))
    report = {"format": "moonrobo.aligned-motion-verification.v1",
              "manifest_sha256": motion.manifest_sha256,
              "model_sha256": _file_sha256(args.model),
              "clip_count": len(motion.names), "source_frames": motion.manifest["source_frames"],
              "resampled_frames": motion.num_frames, "reset_bins": motion.num_bins,
              "control_dt": CONTROL_DT, "all_kinematics_finite": True,
              "all_clip_hashes_verified": True, "source_fps": motion.source_fps,
              "tracked_body_count": int(motion.body_p.shape[1]),
              "reference_root_height_min_m": root_height_min,
              "reference_root_height_max_m": root_height_max,
              "reference_upright_z_min": upright_min,
              "clip_names": motion.names,
              "train_evaluation_overlap": sorted(set(motion.manifest["splits"]["train"]) &
                                                  set(motion.manifest["splits"]["evaluation"])),
              "unseen_generalization_evaluated": False,
              "bones_seed_acquired": bool(motion.manifest.get("bones_seed_acquired", False))}
    Path(args.report).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
