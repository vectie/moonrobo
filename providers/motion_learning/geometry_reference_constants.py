"""Independent FP64 MJCF rotation constants for corrected-math controls.

Use MuJoCo's quaternion-to-matrix routine in double precision and round once
to the state's dtype. No tensor is copied from a native learning result.
Original SMC source and original-SMC benchmark inputs remain unchanged.
"""
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import numpy as np
import torch
import mujoco
from supermimic.kinematics import G1Kinematics
from supermimic.robot import MJCF_PATH


def oracle_rotations(names):
    model=mujoco.MjModel.from_xml_path(MJCF_PATH)
    matrices=[]
    for name in names:
        quaternion=model.body(name).quat.copy()
        assert abs(np.linalg.norm(quaternion)-1)<1e-12
        matrix=np.empty(9,dtype=np.float64)
        mujoco.mju_quat2Mat(matrix,quaternion)
        matrix=matrix.reshape(3,3)
        assert np.max(np.abs(matrix.T@matrix-np.eye(3)))<1e-12
        assert abs(np.linalg.det(matrix)-1)<1e-12
        matrices.append(matrix)
    return np.stack(matrices)


@contextmanager
def fp64_robot_constants():
    original=G1Kinematics.__init__
    def initialize(self,*args,**kwargs):
        original(self,*args,**kwargs)
        self.off_R=torch.as_tensor(oracle_rotations(self.body_names),device=self.off_R.device,dtype=self.off_R.dtype)
    G1Kinematics.__init__=initialize
    try:yield
    finally:G1Kinematics.__init__=original


@contextmanager
def captured_padding(cache,receipt):
    """Freeze only previously measured padding; kernel replay is separate."""
    from compiler_reference_contract_f import normalized_padding_key
    from torch._inductor.fx_passes import pad_mm
    path=Path(cache);digest=hashlib.sha256(path.read_bytes()).hexdigest()
    choices={};used=[];unknown=[]
    for key,value in json.loads(path.read_text())['cache'].items():
        if type(value) is not bool:continue
        key=normalized_padding_key(key)
        assert key not in choices or choices[key]==value
        choices[key]=value
    original=pad_mm.get_cached_should_pad
    def lookup(key):
        normalized=normalized_padding_key(key)
        if normalized not in choices:
            unknown.append(key);return original(key)
        used.append(dict(key=key,value=choices[normalized]));return choices[normalized]
    pad_mm.get_cached_should_pad=lookup
    try:yield
    finally:
        pad_mm.get_cached_should_pad=original
        assert hashlib.sha256(path.read_bytes()).hexdigest()==digest
        Path(receipt).write_text(json.dumps(dict(source=str(path),sha256=digest,used=used,unknown=unknown),indent=2))
