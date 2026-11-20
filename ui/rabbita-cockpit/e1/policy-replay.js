const vector = (value, size) => Array.isArray(value) && value.length === size && value.every(Number.isFinite);
const elbows = ["l_arm_elbow_pitch_joint", "r_arm_elbow_pitch_joint"];

export function parsePolicyReplay(tape, names) {
  if (tape?.format !== "moonrobo.e1-actor-policy-replay.v1" || tape.published !== false ||
      tape.source_kind !== "recorded-input" || tape.fixed_motor_records !== 22 || tape.step_ms !== 20 ||
      !Number.isFinite(tape.maximum_authority) || tape.maximum_authority <= 0 || tape.maximum_authority > 1 ||
      !/^[a-f0-9]{64}$/.test(tape.model_id ?? "") || names.length !== 23 ||
      !Array.isArray(tape.names) || tape.names.length !== 23 || new Set(tape.names).size !== 23 ||
      !names.every((name, i) => name === tape.names[i]) || !elbows.every(name => names.includes(name)) ||
      !Array.isArray(tape.frames) || tape.frames.length < 2) throw Error("推理记录的来源或关节不匹配");
  for (const [i, frame] of tape.frames.entries()) {
    if (frame.at_ms !== i * 20 || !["baseline", "policy", "return"].includes(frame.phase) ||
        !Number.isFinite(frame.authority) || frame.authority < 0 || frame.authority > tape.maximum_authority ||
        (frame.phase !== "policy" && frame.authority !== 0) ||
        ![frame.raw, frame.applied, frame.measured].every(pose => vector(pose, 30) && Math.hypot(...pose.slice(3, 7)) > .5))
      throw Error("推理记录缺帧或姿态无效");
    for (let joint = 0; joint < 23; joint++) {
      if (!elbows.includes(names[joint]) && frame.applied[7 + joint] !== tape.frames[0].applied[7 + joint])
        throw Error("推理候选改变了非肘关节");
    }
  }
  return tape;
}

export function policyCurves(tape, joint) {
  if (!Number.isInteger(joint) || joint < 0 || joint >= 23) throw Error("无效推理关节");
  return ["raw", "applied", "measured"].map(source => tape.frames.map(frame => frame[source][7 + joint] * 180 / Math.PI));
}
