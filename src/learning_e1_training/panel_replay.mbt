///|
priv struct PanelReplay {
  joints : Array[String]
  tracks : Map[Int32, @buffer.Buffer]
  workflow : Map[Int32, @buffer.Buffer]?
}

///|
/// Store frame zero and every post-step physical state, including termination.
fn PanelReplay::capture(
  self : PanelReplay,
  tr : @aligned.Transition,
  motion : @aligned.MotionLibrary,
) -> Unit {
  let clip = motion.clip_id[tr.frame]
  let buffer = if tr.ep_step == 0 {
    let b = @buffer.Buffer()
    self.tracks[clip] = b
    self.pose(b, @aligned.unflatten_state(tr.s))
    b
  } else {
    self.tracks[clip]
  }
  self.pose(buffer, @aligned.unflatten_state(tr.s1))
}

///|
fn PanelReplay::pose(
  self : PanelReplay,
  buffer : @buffer.Buffer,
  state : @aligned.State,
) -> Unit {
  let q = @aligned.mat_to_quat(state.rotation)
  for v in state.p {
    buffer.write_float_le(Float::from_double(v))
  }
  for i in [1, 2, 3, 0] {
    buffer.write_float_le(Float::from_double(q[i]))
  }
  for i in 0..<self.joints.length() {
    buffer.write_float_le(Float::from_double(state.q[i]))
  }
}

///|
async fn PanelReplay::save(
  self : PanelReplay,
  directory : String,
  report : Json,
) -> Unit {
  @fs.mkdir(directory, recursive=true)
  let clips : Array[Json] = json_field(report, "per_clip")
  guard self.tracks.length() == clips.length() else {
    fail("replay clip count differs")
  }
  let manifest : Array[Json] = []
  for row in clips {
    let i : Int32 = json_field(json_field(row, "metadata"), "clip_index")
    let steps : Int32 = json_field(row, "executed_steps")
    let data = self.tracks[i].to_bytes()
    if self.workflow is Some(buffers) {
      let metrics = buffers[i].to_bytes()
      assert_eq(metrics.length(), steps * 11 * 4)
      @fs.write_file(
        directory + "/" + i.to_string() + ".metrics.f32",
        metrics,
        create_mode=CreateNew,
      )
    }
    let file = i.to_string() + ".f32"
    guard data.length() == (steps + 1) * (7 + self.joints.length()) * 4 else {
      fail("replay frame count differs")
    }
    @fs.write_file(directory + "/" + file, data, create_mode=CreateNew)
    manifest.push({
      "id": (json_field(row, "clip_id") : Json),
      "file": Json(file),
      "sha256": Json(@artifacts.sha256(data)),
      "frames": Json(steps + 1),
    })
  }
  let meta : Json = {
    "format": "moonrobo.physical-poses.f32le.v1",
    "control_hz": 50,
    "joints": self.joints.to_json(),
    "clips": Json(manifest),
  }
  @fs.write_file(
    directory + "/poses.json",
    @utf8.encode(meta.stringify()),
    create_mode=CreateNew,
  )
}

///|
/// After each real control step, keep its actual reward, two termination
/// residuals and eight signed reward contributions, in evaluator order.
fn PanelReplay::capture_workflow(
  self : PanelReplay,
  tr : @aligned.Transition,
  motion : @aligned.MotionLibrary,
  kin : @aligned.Kinematics,
  inspect : () -> @aligned.State raise,
) -> Unit raise {
  guard self.workflow is Some(buffers) else { return }
  let s = inspect()
  let ref = motion.states[tr.frame + 1]
  let cfg = @aligned.RewardConfig::default()
  let t = @aligned.reward(
    kin,
    s,
    ref,
    motion.bodies[tr.frame + 1],
    tr.a,
    tr.a_prev,
    cfg~,
  )
  let z = (s.p[2] - ref.p[2]).abs()
  let tilt = (s.rotation[8] - ref.rotation[8]).abs()
  assert_eq(t.reward, tr.r)
  assert_eq(z > cfg.term_height || tilt > cfg.term_tilt, tr.terminated)
  let clip = motion.clip_id[tr.frame]
  let b = if tr.ep_step == 0 {
    let new_buffer = @buffer.Buffer()
    buffers[clip] = new_buffer
    new_buffer
  } else {
    buffers[clip]
  }
  let term = (x : Double, std : Double) => @math.exp(-x / (std * std))
  let values = [
    term(t.body_pos, cfg.body_pos_std),
    term(t.body_ori, cfg.body_ori_std),
    term(t.body_linvel, cfg.body_linvel_std),
    term(t.body_angvel, cfg.body_angvel_std),
    0.5 * term(t.root_pos, cfg.root_pos_std),
    0.5 * term(t.root_ori, cfg.root_ori_std),
    cfg.w_action_rate * t.action_rate,
    cfg.w_joint_limit * t.joint_limit,
  ].map(x => x * @aligned.control_dt)
  guard (values.fold(init=0.0, (sum, x) => sum + x) - tr.r).abs() < 1.0e-12 else {
    fail("step contributions do not reconstruct the measured reward")
  }
  for x in [tr.r, z, tilt] + values {
    b.write_float_le(Float::from_double(x))
  }
}
