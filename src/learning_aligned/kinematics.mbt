///|
pub(all) struct State {
  p : Array[Double]
  rotation : Array[Double]
  v : Array[Double]
  w : Array[Double]
  q : Array[Double]
  qd : Array[Double]
} derive(Debug)

///|
pub fn flatten_state(s : State) -> Array[Double] {
  let out = s.p.copy()
  out.append(mat_to_quat(s.rotation))
  out.append(s.v)
  out.append(s.w)
  out.append(s.q)
  out.append(s.qd)
  out
}

///|
pub fn unflatten_state(x : Array[Double]) -> State {
  {
    p: x[0:3].to_owned(),
    rotation: quat_to_mat(x[3:7].to_owned()),
    v: x[7:10].to_owned(),
    w: x[10:13].to_owned(),
    q: x[13:42].to_owned(),
    qd: x[42:71].to_owned(),
  }
}

///|
pub(all) struct BodySpec {
  name : String
  parent : Int32
  joint : Int32
  axis : Array[Double]
  offset_p : Array[Double]
  offset_rotation : Array[Double]
  pivot : Array[Double]
  qref : Double
} derive(Debug, @json.FromJson)

///|
pub(all) struct Kinematics {
  bodies : Array[BodySpec]
  tracked : Array[Int32]
  q_lo : Array[Double]
  q_hi : Array[Double]
} derive(Debug, @json.FromJson)

///|
pub(all) struct BodyState {
  p : Array[Double]
  rotation : Array[Double]
  v : Array[Double]
  w : Array[Double]
} derive(Debug)

///|
pub fn Kinematics::forward(
  self : Kinematics,
  s : State,
  all_bodies~ : Bool = false,
) -> Array[BodyState] {
  let out : Array[BodyState] = []
  for spec in self.bodies {
    if spec.parent < 0 {
      out.push({ p: s.p, rotation: s.rotation, v: s.v, w: s.w, })
      continue
    }
    let par = out[spec.parent]
    let mut p = vec_add(par.p, mat_vec(par.rotation, spec.offset_p))
    let off = mat_mul(par.rotation, spec.offset_rotation)
    let rotation = if spec.joint < 0 {
      off
    } else {
      mat_mul(off, axis_angle_to_mat(spec.axis, s.q[spec.joint] - spec.qref))
    }
    let pivot = vec_add(p, mat_vec(off, spec.pivot))
    let jw = if spec.joint < 0 {
      [0.0, 0.0, 0.0]
    } else {
      p = vec_sub(pivot, mat_vec(rotation, spec.pivot))
      vec_scale(mat_vec(off, spec.axis), s.qd[spec.joint])
    }
    let v = vec_add(
      vec_add(par.v, cross(par.w, vec_sub(p, par.p))),
      cross(jw, vec_sub(p, pivot)),
    )
    out.push({ p, rotation, v, w: vec_add(par.w, jw), })
  }
  if all_bodies {
    out
  } else {
    self.tracked.map(i => out[i])
  }
}
