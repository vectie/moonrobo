///|
pub(all) struct MotionClip {
  name : String
  sha256 : String
  // Source CSV columns: xyz, quaternion xyzw, 29 joints.
  rows : Array[Array[Double]]
} derive(Debug)

///|
pub(all) struct MotionLibrary {
  orthonormal_heading : Bool
  names : Array[String]
  source_sha256 : Array[String]
  source_fps : Double
  states : FrameStore[State]
  bodies : FrameStore[Array[BodyState]]
  clip_start : Array[Int32]
  clip_end : Array[Int32]
  clip_id : FrameStore[Int32]
  bins : Array[ResetBin]
  frame_bin : FrameStore[Int32]
} derive(Debug)

///|
pub fn MotionLibrary::new(
  clips : Array[MotionClip],
  kin : Kinematics,
  source_fps~ : Double = 30.0,
  compute_body_features~ : Bool = true,
  exact_control_frames~ : Bool = false,
) -> MotionLibrary raise {
  guard !clips.is_empty() && finite(source_fps) && source_fps > 0.0 else {
    fail("real motion clips and positive finite FPS required")
  }
  guard !exact_control_frames || source_fps == 1.0 / control_dt else {
    fail("an exact control-frame grid requires the control frequency")
  }
  let names : Array[String] = []
  let hashes : Array[String] = []
  let states : Array[State] = []
  let bodies : Array[Array[BodyState]] = []
  let starts : Array[Int32] = []
  let ends : Array[Int32] = []
  let ids : Array[Int32] = []
  let bins : Array[ResetBin] = []
  let frame_bin : Array[Int32] = []
  for clip_index, clip in clips {
    guard !names.contains(clip.name) else {
      fail("clip identifiers must be unique")
    }
    guard clip.rows.length() >= 2 else {
      fail("clip requires at least two CSV frames")
    }
    for row in clip.rows {
      guard row.length() == 36 && row.all(finite) else {
        fail("expected finite 36-column G1 CSV")
      }
      guard square_norm(row[3:7].to_owned()).sqrt() >= 1.0e-6 else {
        fail("invalid root quaternion")
      }
    }
    let n = if exact_control_frames {
      clip.rows.length()
    } else {
      @math.floor(
        (clip.rows.length() - 1).to_double() / source_fps / control_dt,
      ).to_int() +
      1
    }
    guard n >= 2 else { fail("clip shorter than one control transition") }
    let p : Array[Array[Double]] = []
    let rotation : Array[Array[Double]] = []
    let q : Array[Array[Double]] = []
    for i in 0..<n {
      let time = if exact_control_frames {
        i.to_double()
      } else {
        i.to_double() * control_dt * source_fps
      }
      let left = @math.floor(time).to_int().min(clip.rows.length() - 2)
      let alpha = (time - left.to_double()).max(0.0).min(1.0)
      let a = clip.rows[left]
      let b = clip.rows[left + 1]
      p.push(Array::makei(3, j => a[j] * (1.0 - alpha) + b[j] * alpha))
      q.push(Array::makei(29, j => a[j + 7] * (1.0 - alpha) + b[j + 7] * alpha))
      rotation.push(
        quat_to_mat(
          quat_slerp([a[6], a[3], a[4], a[5]], [b[6], b[3], b[4], b[5]], alpha),
        ),
      )
    }
    let start = states.length()
    starts.push(start)
    ends.push(start + n - 1)
    names.push(clip.name)
    hashes.push(clip.sha256)
    for i in 0..<n {
      let left = (i - 1).max(0)
      let right = (i + 1).min(n - 1)
      let dt = (right - left).to_double() * control_dt
      let state : State = {
        p: p[i],
        rotation: rotation[i],
        v: vec_scale(vec_sub(p[right], p[left]), 1.0 / dt),
        w: vec_scale(
          so3_log(mat_mul(rotation[right], transpose(rotation[left]))),
          1.0 / dt,
        ),
        q: q[i],
        qd: vec_scale(vec_sub(q[right], q[left]), 1.0 / dt),
      }
      states.push(state)
      ids.push(clip_index)
      if compute_body_features {
        bodies.push(kin.forward(state))
      }
      frame_bin.push(0)
    }
    let count = (n - 2) / 50 + 1
    for b in 0..<count {
      let bin_start = start + b * 50
      let bin_index = bins.length()
      bins.push({ start: bin_start, clip_end: start + n - 1, })
      let end = (bin_start + 50).min(start + n)
      for f in bin_start..<end {
        frame_bin[f] = bin_index
      }
      if end == start + n - 1 {
        frame_bin[end] = bin_index
      }
    }
  }
  {
    names,
    source_sha256: hashes,
    source_fps,
    states: FrameStore::eager(states),
    bodies: FrameStore::eager(bodies),
    clip_start: starts,
    clip_end: ends,
    clip_id: FrameStore::eager(ids),
    bins,
    frame_bin: FrameStore::eager(frame_bin),
    orthonormal_heading: false,
  }
}

///|
pub fn MotionLibrary::future_frames(
  self : MotionLibrary,
  frame : Int32,
  k : Int32,
) -> Array[Int32] {
  if k < 0 || k > self.states.materialize_limit {
    abort("reference preview exceeds max_gather_frames")
  }
  let end = self.clip_end[self.clip_id[frame]]
  Array::makei(k, i => (frame + i + 1).min(end))
}

///|
pub fn MotionLibrary::goal(
  self : MotionLibrary,
  frame : Int32,
  k : Int32,
) -> Array[Double] {
  let out : Array[Double] = []
  let current = self.states[frame]
  let ht = transpose(yaw_mat(current.rotation, atlas=self.orthonormal_heading))
  for f in self.future_frames(frame, k) {
    append_goal_frame(out, current, self.states[f], ht)
  }
  out
}

///|
fn append_goal_frame(
  out : Array[Double],
  current : State,
  future : State,
  heading_transpose : Array[Double],
) -> Unit {
  out.append(mat_vec(heading_transpose, vec_sub(future.p, current.p)))
  out.append(mat_to_6d(mat_mul(heading_transpose, future.rotation)))
  out.append(mat_vec(transpose(future.rotation), future.v))
  out.append(mat_vec(transpose(future.rotation), future.w))
  out.append(future.q)
  out.append(vec_scale(future.qd, 0.1))
}

///|
/// Encode already selected preview states using the same Float64 operations as
/// `MotionLibrary::goal`. Callers retain the original future-frame ordering and
/// repeat the final state when a preview extends past the reference clip.
pub fn goal_from_states(
  current : State,
  futures : Array[State],
  atlas~ : Bool = false,
) -> Array[Double] {
  let out : Array[Double] = []
  let ht = transpose(yaw_mat(current.rotation, atlas~))
  for future in futures {
    append_goal_frame(out, current, future, ht)
  }
  out
}

///|
pub fn parse_motion_csv(text : String) -> Array[Array[Double]] raise {
  let out : Array[Array[Double]] = []
  for line in text.split("\n") {
    let line = match line.split_once("#") {
      Some((data, _)) => data.trim()
      None => line.trim()
    }
    if line.is_empty() {
      continue
    }
    let values : Array[Double] = []
    for value in line.split(",") {
      values.push(@string.parse_double(value.trim()))
    }
    guard values.length() == 36 && values.all(finite) else {
      fail("expected finite 36-column motion CSV")
    }
    out.push(values)
  }
  out
}
