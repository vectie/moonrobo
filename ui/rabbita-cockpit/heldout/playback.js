export const robots = ["g1", "e1"];

export function fineTunedPanel(panel, scores, poses) {
  if (poses.control_hz !== panel.control_hz ||
      JSON.stringify(poses.joints) !== JSON.stringify(panel.robots.e1.joints) ||
      poses.clips.length !== panel.clips.length || scores.development_motions.length !== panel.clips.length ||
      scores.actor_sha256.baseline !== panel.robots.e1.actor_sha256) throw Error("Fine-tuned E1 catalog mismatch.");
  const clips = panel.clips.map((clip, i) => {
    const motion = scores.development_motions[i], pose = poses.clips[i];
    if (motion.motion !== clip.id || pose.id !== clip.id || pose.file !== i + ".f32" ||
        motion.expected_steps !== clip.expected_steps || pose.frames !== motion.candidate_steps + 1) {
      throw Error("Fine-tuned E1 recording mismatch.");
    }
    return {...clip, e1: {...clip.e1, sha256: pose.sha256, steps: motion.candidate_steps,
      completed: motion.candidate_completed, termination_frame: motion.candidate_completed ? null : motion.candidate_steps,
      score: motion.candidate_return}};
  });
  return validatePanel({...panel, clips, robots: {...panel.robots, e1: {...panel.robots.e1, actor_sha256: scores.actor_sha256.candidate}}});
}

export function guardedPanel(panel, study) {
  if (study.panel_sha256 !== panel.panel_sha256 || study.clips.length !== panel.clips.length) {
    throw Error("Geometry-checked replay panel mismatch.");
  }
  const clips = panel.clips.map((clip, i) => {
    const entry = study.clips[i];
    const original = entry.variants.find(v => v.mode === "original");
    const result = entry.variants.find(v => v.mode === "arms-guarded");
    if (entry.id !== clip.id || entry.expected_steps !== clip.expected_steps ||
        original?.physical_sha256 !== clip.e1.sha256 || !result) throw Error("Replay evidence mismatch.");
    return {...clip, e1: {...clip.e1, sha256: result.physical_sha256, steps: result.steps,
      completed: result.completed, termination_frame: result.completed ? null : result.steps, score: result.normalized_return}};
  });
  return validatePanel({...panel, clips});
}

export function frameAt(step, track) {
  return Math.min(Math.max(0, Math.floor(step)), track.steps);
}

export function decodeTrack(buffer, track, jointCount) {
  const width = 7 + jointCount;
  if (buffer.byteLength !== (track.steps + 1) * width * 4) {
    throw Error("The recording length does not match the benchmark.");
  }
  const values = new Float32Array(buffer);
  if (!values.every(Number.isFinite)) throw Error("Invalid recorded pose.");
  return step => {
    const offset = frameAt(step, track) * width;
    return values.subarray(offset, offset + width);
  };
}

export function validatePanel(panel) {
  if (panel.format !== "moonrobo.heldout-pair.v1" || panel.control_hz !== 50 ||
      panel.clips.length !== 40 || new Set(panel.clips.map(c => c.id)).size !== 40) {
    throw Error("Unexpected motion catalog.");
  }
  for (const [i, clip] of panel.clips.entries()) {
    if (!/^(dance|karate)\/[a-zA-Z0-9_]+$/.test(clip.id) ||
        !Number.isSafeInteger(clip.expected_steps) || clip.expected_steps <= 0) throw Error("Invalid motion.");
    for (const robot of robots) {
      const r = clip[robot];
      if (!Number.isInteger(r.steps) || r.steps <= 0 || r.steps > clip.expected_steps ||
          !Number.isFinite(r.score) || r.file !== robot + "/" + i + ".f32" ||
          !/^[a-f0-9]{64}$/.test(r.sha256) ||
          (r.completed ? r.steps !== clip.expected_steps || r.termination_frame !== null : r.termination_frame !== r.steps)) {
        throw Error("Invalid rollout outcome for " + clip.id);
      }
    }
  }
  return panel;
}
