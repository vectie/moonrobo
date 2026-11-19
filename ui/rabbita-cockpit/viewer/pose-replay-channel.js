// Shared world-pose contract for recorded experiments and future live MuJoCo
// sessions. This module has no DOM, Three.js, transport, or clock dependency.
export const POSE_REPLAY_FORMAT = 'moonrobo.pose-replay.v1'
export const POSE_REPLAY_LIMITS = Object.freeze({
  bodies: 512,
  visuals: 2048,
  clips: 256,
  tracksPerClip: 8,
  framesPerTrack: 100000,
  frames: 200000,
  bodyPoses: 2000000,
})

const validatedClips = new WeakSet()
const validatedModels = new WeakSet()
const TRACK_KINDS = new Set(['physics', 'reference'])

function fail(path, reason) {
  throw new Error(`Invalid pose replay: ${path} ${reason}`)
}

function record(value, path) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail(path, 'must be an object')
  return value
}

function text(value, path, maxLength = 256) {
  if (typeof value !== 'string' || !value.length || value.length > maxLength || /[\u0000-\u001f]/u.test(value)) {
    fail(path, 'must be a nonempty, bounded string without control characters')
  }
  return value
}

function finite(value, path, min = -1e9, max = 1e9) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    fail(path, `must be a finite number in [${min}, ${max}]`)
  }
  return value
}

function array(value, path, limit, allowEmpty = false) {
  if (!Array.isArray(value) || (!allowEmpty && !value.length) || value.length > limit) {
    fail(path, `must be an array with ${allowEmpty ? '0' : '1'}–${limit} entries`)
  }
  return value
}

function vector(value, count, path, min = -1e9, max = 1e9) {
  if (!Array.isArray(value) || value.length !== count) fail(path, `must have ${count} numbers`)
  return value.map((component, index) => finite(component, `${path}[${index}]`, min, max))
}

function quaternion(value, path) {
  const q = vector(value, 4, path)
  const norm = Math.hypot(...q)
  if (Math.abs(norm * norm - 1) > 1e-5) fail(path, 'must be a unit quaternion (squared norm tolerance 1e-5)')
  return q.map((component) => component / norm)
}

function sha256(value, path) {
  if (typeof value !== 'string' || !/^[a-f0-9]{64}$/u.test(value)) fail(path, 'must be a lowercase SHA-256 hex digest')
  return value
}

function uniqueId(value, seen, path) {
  const id = text(value, path, 128)
  if (seen.has(id)) fail(path, `duplicates ${id}`)
  seen.add(id)
  return id
}

function geometry(value, path) {
  record(value, path)
  switch (value.kind) {
    case 'mesh': {
      const hash = sha256(value.sha256, `${path}.sha256`)
      const asset = text(value.asset, `${path}.asset`, 80)
      if (!new RegExp(`^${hash}\\.(obj|stl)$`, 'u').test(asset)) fail(`${path}.asset`, 'must be a lowercase content-addressed OBJ or STL basename')
      const scale = vector(value.scale ?? [1, 1, 1], 3, `${path}.scale`, 1e-9, 1e6)
      return { ...value, kind: 'mesh', sha256: hash, asset, scale }
    }
    case 'box':
      return { ...value, size: vector(value.size, 3, `${path}.size`, 1e-9, 1e6) }
    case 'sphere':
      return { ...value, radius: finite(value.radius, `${path}.radius`, 1e-9, 1e6) }
    case 'ellipsoid':
      return { ...value, radii: vector(value.radii, 3, `${path}.radii`, 1e-9, 1e6) }
    case 'cylinder':
    case 'capsule':
      return {
        ...value,
        radius: finite(value.radius, `${path}.radius`, 1e-9, 1e6),
        length: finite(value.length, `${path}.length`, value.kind === 'capsule' ? 0 : 1e-9, 1e6),
      }
    case 'plane':
      return { ...value, size: vector(value.size, 2, `${path}.size`, 0, 1e6) }
    default:
      fail(`${path}.kind`, 'is not a supported mesh or primitive')
  }
}

export function validatePoseModel(value) {
  if (validatedModels.has(value)) return value
  const model = record(value, 'model')
  const id = text(model.id, 'model.id', 128)
  const hash = sha256(model.sha256, 'model.sha256')
  if (model.coordinate_system !== 'right-handed-z-up') fail('model.coordinate_system', 'must be right-handed-z-up')
  const bodyIds = new Set()
  const bodies = array(model.bodies, 'model.bodies', POSE_REPLAY_LIMITS.bodies).map((body, index) => {
    const path = `model.bodies[${index}]`
    record(body, path)
    // MoonBit omits None fields in native JSON; both wire forms denote a root.
    if (body.parent_id != null && !bodyIds.has(body.parent_id)) fail(`${path}.parent_id`, 'must reference an earlier body')
    return {
      ...body,
      id: uniqueId(body.id, bodyIds, `${path}.id`),
      name: text(body.name, `${path}.name`),
      parent_id: body.parent_id == null ? null : text(body.parent_id, `${path}.parent_id`, 128),
    }
  })
  const parentById = new Map(bodies.map((body) => [body.id, body.parent_id]))
  for (const body of bodies) {
    const visited = new Set([body.id])
    let parent = body.parent_id
    while (parent !== null) {
      if (!bodyIds.has(parent)) fail(`body ${body.id}.parent_id`, `references unknown body ${parent}`)
      if (visited.has(parent)) fail(`body ${body.id}.parent_id`, 'contains a cycle')
      visited.add(parent)
      parent = parentById.get(parent)
    }
  }
  const visualIds = new Set()
  const visuals = array(model.visuals, 'model.visuals', POSE_REPLAY_LIMITS.visuals).map((visual, index) => {
    const path = `model.visuals[${index}]`
    record(visual, path)
    const bodyId = text(visual.body_id, `${path}.body_id`, 128)
    if (!bodyIds.has(bodyId)) fail(`${path}.body_id`, 'references an unknown body')
    return {
      ...visual,
      id: uniqueId(visual.id, visualIds, `${path}.id`),
      body_id: bodyId,
      geometry: geometry(visual.geometry, `${path}.geometry`),
      local_position: vector(visual.local_position, 3, `${path}.local_position`),
      local_quaternion_wxyz: quaternion(visual.local_quaternion_wxyz, `${path}.local_quaternion_wxyz`),
      rgba: vector(visual.rgba ?? [0.7, 0.75, 0.82, 1], 4, `${path}.rgba`, 0, 1),
    }
  })
  const result = { ...model, id, sha256: hash, bodies, visuals }
  validatedModels.add(result)
  return result
}

function normalizeFrame(value, bodyIds, path) {
  record(value, path)
  const time = finite(value.time_s, `${path}.time_s`, 0, 1e9)
  const seen = new Set()
  const poses = array(value.bodies, `${path}.bodies`, POSE_REPLAY_LIMITS.bodies).map((pose, index) => {
    const posePath = `${path}.bodies[${index}]`
    record(pose, posePath)
    const id = uniqueId(pose.body_id, seen, `${posePath}.body_id`)
    if (!bodyIds.has(id)) fail(`${posePath}.body_id`, 'references an unknown model body')
    return {
      body_id: id,
      position: vector(pose.position, 3, `${posePath}.position`),
      quaternion_wxyz: quaternion(pose.quaternion_wxyz, `${posePath}.quaternion_wxyz`),
    }
  })
  if (seen.size !== bodyIds.size) fail(`${path}.bodies`, 'must include every model body exactly once')
  // Canonical body order makes interpolation O(number of bodies), even when a
  // producer emits the same bodies in a different order on successive frames.
  const byId = new Map(poses.map((pose) => [pose.body_id, pose]))
  return { ...value, time_s: time, bodies: Array.from(bodyIds, (id) => byId.get(id)) }
}

export function validatePoseFrame(value, model) {
  const normalizedModel = validatePoseModel(model)
  return normalizeFrame(value, new Set(normalizedModel.bodies.map((body) => body.id)), 'frame')
}

function normalizeClip(value, bodyIds, budget, path) {
  record(value, path)
  const trackIds = new Set()
  const tracks = array(value.tracks, `${path}.tracks`, POSE_REPLAY_LIMITS.tracksPerClip).map((track, trackIndex) => {
    const trackPath = `${path}.tracks[${trackIndex}]`
    record(track, trackPath)
    if (!TRACK_KINDS.has(track.kind)) fail(`${trackPath}.kind`, 'must be physics or reference')
    const sourceFrames = array(track.frames, `${trackPath}.frames`, POSE_REPLAY_LIMITS.framesPerTrack)
    budget.frames += sourceFrames.length
    budget.bodyPoses += sourceFrames.length * bodyIds.size
    if (budget.frames > POSE_REPLAY_LIMITS.frames || budget.bodyPoses > POSE_REPLAY_LIMITS.bodyPoses) {
      fail(path, 'exceeds the frame/body-pose memory budget')
    }
    let previous = -1
    const frames = sourceFrames.map((frame, frameIndex) => {
      const normalized = normalizeFrame(frame, bodyIds, `${trackPath}.frames[${frameIndex}]`)
      if (normalized.time_s <= previous) fail(`${trackPath}.frames[${frameIndex}].time_s`, 'must strictly increase')
      previous = normalized.time_s
      return normalized
    })
    return {
      ...track,
      id: uniqueId(track.id, trackIds, `${trackPath}.id`),
      label: text(track.label ?? track.id, `${trackPath}.label`),
      frames,
    }
  })
  const clip = {
    ...value,
    id: text(value.id, `${path}.id`, 128),
    label: text(value.label ?? value.id, `${path}.label`),
    source_start_time_s: finite(value.source_start_time_s ?? 0, `${path}.source_start_time_s`, 0, 1e9),
    tracks,
  }
  validatedClips.add(clip)
  return clip
}

export function validatePoseReplay(value) {
  const replay = record(value, 'replay')
  if (replay.format !== POSE_REPLAY_FORMAT) fail('format', `must be ${POSE_REPLAY_FORMAT}`)
  const model = validatePoseModel(replay.model)
  const bodyIds = new Set(model.bodies.map((body) => body.id))
  const clipIds = new Set()
  const budget = { frames: 0, bodyPoses: 0 }
  const clips = array(replay.clips, 'clips', POSE_REPLAY_LIMITS.clips).map((clip, index) => {
    const normalized = normalizeClip(clip, bodyIds, budget, `clips[${index}]`)
    uniqueId(normalized.id, clipIds, `clips[${index}].id`)
    return normalized
  })
  return { ...replay, model, clips }
}

export function slerpQuaternionWxyz(a, b, fraction) {
  const t = finite(fraction, 'interpolation fraction', 0, 1)
  let dot = a.reduce((sum, component, index) => sum + component * b[index], 0)
  const sign = dot < 0 ? -1 : 1
  dot = Math.min(1, Math.abs(dot))
  let wa = 1 - t
  let wb = t
  if (dot < 0.9995) {
    const theta = Math.acos(dot)
    const denominator = Math.sin(theta)
    wa = Math.sin((1 - t) * theta) / denominator
    wb = Math.sin(t * theta) / denominator
  }
  const result = a.map((component, index) => wa * component + wb * sign * b[index])
  const norm = Math.hypot(...result)
  return result.map((component) => component / norm)
}

function interpolateFrame(left, right, time) {
  if (time === left.time_s) return left
  if (time === right.time_s) return right
  const fraction = (time - left.time_s) / (right.time_s - left.time_s)
  return {
    time_s: time,
    bodies: left.bodies.map((pose, index) => {
      const next = right.bodies[index]
      return {
        body_id: pose.body_id,
        position: pose.position.map((component, axis) => component + (next.position[axis] - component) * fraction),
        quaternion_wxyz: slerpQuaternionWxyz(pose.quaternion_wxyz, next.quaternion_wxyz, fraction),
      }
    }),
  }
}

export function createReplaySampler(sourceClip) {
  let clip = sourceClip
  if (!validatedClips.has(clip)) {
    // Standalone callers can still use the sampler without a full document;
    // infer the body set once, then apply the same validation to every track.
    const firstBodies = sourceClip?.tracks?.[0]?.frames?.[0]?.bodies
    const ids = new Set()
    array(firstBodies, 'first frame bodies', POSE_REPLAY_LIMITS.bodies).forEach((body, index) => {
      uniqueId(body?.body_id, ids, `first frame bodies[${index}].body_id`)
    })
    clip = normalizeClip(sourceClip, ids, { frames: 0, bodyPoses: 0 }, 'clip')
  }
  const startTime = Math.min(...clip.tracks.map((track) => track.frames[0].time_s))
  const endTime = Math.max(...clip.tracks.map((track) => track.frames.at(-1).time_s))
  return Object.freeze({
    startTime,
    endTime,
    duration: endTime - startTime,
    sample(time) {
      finite(time, 'sample time', 0, 1e9)
      return clip.tracks.map((track) => {
        const frames = track.frames
        const first = frames[0]
        const last = frames.at(-1)
        const waiting = time < first.time_s
        const ended = time > last.time_s
        let frame = null
        if (!waiting) {
          if (time >= last.time_s) frame = last
          else {
            let low = 0
            let high = frames.length - 1
            while (high - low > 1) {
              const middle = (low + high) >>> 1
              if (frames[middle].time_s <= time) low = middle
              else high = middle
            }
            frame = interpolateFrame(frames[low], frames[high], time)
          }
        }
        return {
          trackId: track.id,
          kind: track.kind,
          label: track.label,
          frame,
          state: waiting ? 'waiting' : ended ? 'ended' : 'active',
          ended,
          visible: !waiting,
          startTime: first.time_s,
          endTime: last.time_s,
          termination: track.termination ?? null,
        }
      })
    },
  })
}

// A transport-neutral live channel. The transport owns reconnects/backpressure;
// reset() explicitly begins a new clock epoch. Old/out-of-order frames cannot
// silently move the robot backwards in time.
export function createPoseFrameChannel(sourceModel, { onFrame } = {}) {
  const model = validatePoseModel(sourceModel)
  if (onFrame !== undefined && typeof onFrame !== 'function') throw new TypeError('Pose frame listener must be a function')
  const bodyIds = new Set(model.bodies.map((body) => body.id))
  const listeners = new Set(onFrame ? [onFrame] : [])
  const latest = new Map()
  let disposed = false
  return Object.freeze({
    model,
    push(trackId, sourceFrame, options = {}) {
      if (disposed) throw new Error('Pose frame channel is disposed')
      text(trackId, 'trackId', 128)
      const kind = options.kind ?? 'physics'
      if (!TRACK_KINDS.has(kind)) fail('track kind', 'is unsupported')
      if ((options.modelId !== undefined && options.modelId !== model.id) ||
          (options.modelSha256 !== undefined && (typeof options.modelSha256 !== 'string' || options.modelSha256.toLowerCase() !== model.sha256))) {
        fail('live frame model identity', 'does not match the loaded model')
      }
      const frame = normalizeFrame(sourceFrame, bodyIds, 'live frame')
      const previous = latest.get(trackId)
      if (previous && frame.time_s <= previous.frame.time_s) fail('live frame time_s', 'must strictly increase; call reset for a new session')
      if (!previous && latest.size >= POSE_REPLAY_LIMITS.tracksPerClip) fail('live tracks', 'exceeds the track budget')
      const sample = { trackId, kind, frame, state: 'active', ended: false, visible: options.visible !== false }
      latest.set(trackId, sample)
      for (const listener of listeners) listener(sample)
      return sample
    },
    subscribe(listener) {
      if (disposed) throw new Error('Pose frame channel is disposed')
      if (typeof listener !== 'function') throw new TypeError('Pose frame listener must be a function')
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
    reset() { latest.clear() },
    dispose() { disposed = true; latest.clear(); listeners.clear() },
  })
}
