const vector = (value, size) => Array.isArray(value) && value.length === size && value.every(Number.isFinite);

export function parseGestureReplay(tape, names) {
  if (tape?.format !== "moonrobo.e1-gesture-replay.v1" || tape.published !== false || tape.step_ms !== 20 ||
      typeof tape.reference_id !== "string" || !tape.reference_id || names.length !== 23 ||
      !Array.isArray(tape.names) || tape.names.length !== 23 || new Set(tape.names).size !== 23 ||
      !names.every((name, i) => name === tape.names[i]) || !Array.isArray(tape.frames) || tape.frames.length < 2)
    throw Error("动作回放的关节或记录格式不匹配");
  let previous = -1;
  for (const frame of tape.frames) {
    if (!Number.isInteger(frame.at_ms) || frame.at_ms % 20 || frame.at_ms <= previous ||
        (previous < 0 && frame.at_ms !== 0) ||
        ![frame.reference, frame.actor, frame.measured].every(pose =>
          vector(pose, 30) && Math.hypot(...pose.slice(3, 7)) > .5))
      throw Error("动作回放存在无效姿态或时间顺序");
    previous = frame.at_ms;
  }
  return tape;
}

export function replayFrameAt(tape, milliseconds) {
  let low = 0, high = tape.frames.length - 1;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (tape.frames[mid].at_ms <= milliseconds) low = mid;
    else high = mid - 1;
  }
  return low;
}

export function replayCurves(tape, joint) {
  if (!Number.isInteger(joint) || joint < 0 || joint >= 23) throw Error("无效回放关节");
  return ["reference", "actor"].map(source => tape.frames.map(frame => frame[source][7 + joint] * 180 / Math.PI));
}
