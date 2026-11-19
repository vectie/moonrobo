// Deferred regression suite. Run with node --test only when the machine is
// available; authoring these cases does not execute training or simulation.
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  createPoseFrameChannel,
  createReplaySampler,
  slerpQuaternionWxyz,
  validatePoseReplay,
} from './pose-replay-channel.js'

const identity = [1, 0, 0, 0]
const frame = (time, x, q = identity) => ({
  time_s: time,
  bodies: [
    { body_id: '0', position: [0, 0, 0], quaternion_wxyz: [...identity] },
    { body_id: '1', position: [x, 0, 1], quaternion_wxyz: [...q] },
  ],
})

function fixture() {
  return {
    format: 'moonrobo.pose-replay.v1',
    experiment_id: 'recorded-experiment',
    model: {
      id: 'robot', sha256: '0'.repeat(64), coordinate_system: 'right-handed-z-up',
      bodies: [{ id: '0', name: 'world', parent_id: null }, { id: '1', name: 'base', parent_id: '0' }],
      visuals: [{ id: 'base-shape', body_id: '1', geometry: { kind: 'sphere', radius: 0.1 }, local_position: [0, 0, 0], local_quaternion_wxyz: [...identity] }],
    },
    clips: [{ id: 'walk', label: 'Walk', tracks: [
      { id: 'physical', kind: 'physics', frames: [frame(0, 0), frame(1, 2)] },
      { id: 'target', kind: 'reference', frames: [frame(0, 0), frame(2, 4)] },
    ] }],
  }
}

test('interpolates floating world translation without adding parent transforms', () => {
  const replay = validatePoseReplay(fixture())
  assert.equal(replay.experiment_id, 'recorded-experiment')
  const samples = createReplaySampler(replay.clips[0]).sample(0.5)
  assert.deepEqual(samples[0].frame.bodies[1].position, [1, 0, 1])
  assert.deepEqual(samples[1].frame.bodies[1].position, [1, 0, 1])
  assert.equal(samples[0].state, 'active')
})

test('accepts the native omitted optional parent while still rejecting invalid parents', () => {
  const native = fixture()
  delete native.model.bodies[0].parent_id
  assert.equal(validatePoseReplay(native).model.bodies[0].parent_id, null)
  native.model.bodies[0].parent_id = ''
  assert.throws(() => validatePoseReplay(native), /parent_id/)
})

test('holds the final physical frame while the reference continues', () => {
  const replay = validatePoseReplay(fixture())
  const sampler = createReplaySampler(replay.clips[0])
  const [physical, reference] = sampler.sample(1.5)
  assert.equal(physical.state, 'ended')
  assert.equal(physical.ended, true)
  assert.equal(physical.visible, true)
  assert.equal(physical.frame.time_s, 1)
  assert.deepEqual(physical.frame.bodies[1].position, [2, 0, 1])
  assert.equal(reference.frame.time_s, 1.5)
  assert.deepEqual(reference.frame.bodies[1].position, [3, 0, 1])
  assert.equal(reference.ended, false)
  assert.equal(sampler.endTime, 2)
})

test('does not invent an initial pose before a track begins', () => {
  const input = fixture()
  input.clips[0].tracks[0].frames = [frame(0.5, 1), frame(1, 2)]
  const sampler = createReplaySampler(validatePoseReplay(input).clips[0])
  const sample = sampler.sample(0.2)[0]
  assert.equal(sample.state, 'waiting')
  assert.equal(sample.frame, null)
  assert.equal(sample.visible, false)
})

test('shortest-path slerp handles opposite signs for the same quaternion', () => {
  assert.deepEqual(slerpQuaternionWxyz(identity, [-1, 0, 0, 0], 0.5), identity)
  const halfTurn = slerpQuaternionWxyz(identity, [0, 0, 0, 1], 0.5)
  assert.ok(Math.abs(halfTurn[0] - Math.SQRT1_2) < 1e-12)
  assert.ok(Math.abs(halfTurn[3] - Math.SQRT1_2) < 1e-12)
})

test('canonical body ordering prevents interpolation across the wrong bodies', () => {
  const input = fixture()
  input.clips[0].tracks[0].frames[1].bodies.reverse()
  const sample = createReplaySampler(validatePoseReplay(input).clips[0]).sample(0.5)[0]
  assert.deepEqual(sample.frame.bodies.map((pose) => pose.body_id), ['0', '1'])
  assert.deepEqual(sample.frame.bodies[1].position, [1, 0, 1])
})

test('rejects duplicate times, missing bodies, nonunit quaternions, and nonfinite poses', () => {
  const duplicateTime = fixture()
  duplicateTime.clips[0].tracks[0].frames[1].time_s = 0
  assert.throws(() => validatePoseReplay(duplicateTime), /strictly increase/u)
  const missingBody = fixture()
  missingBody.clips[0].tracks[0].frames[1].bodies.pop()
  assert.throws(() => validatePoseReplay(missingBody), /every model body/u)
  const invalidQuat = fixture()
  invalidQuat.clips[0].tracks[0].frames[0].bodies[1].quaternion_wxyz = [2, 0, 0, 0]
  assert.throws(() => validatePoseReplay(invalidQuat), /unit quaternion/u)
  const nonfinite = fixture()
  nonfinite.clips[0].tracks[0].frames[0].bodies[1].position[0] = NaN
  assert.throws(() => validatePoseReplay(nonfinite), /finite number/u)
})

test('rejects asset traversal and unknown v1 track kinds', () => {
  const traversal = fixture()
  traversal.model.visuals[0].geometry = { kind: 'mesh', sha256: 'a'.repeat(64), asset: '../robot.obj', scale: [1, 1, 1] }
  assert.throws(() => validatePoseReplay(traversal), /content-addressed/u)
  const unknownKind = fixture()
  unknownKind.clips[0].tracks[0].kind = 'prediction'
  assert.throws(() => validatePoseReplay(unknownKind), /physics or reference/u)
})

test('live frame channel checks identity, ordering, copying, and explicit clock reset', () => {
  const model = validatePoseReplay(fixture()).model
  const samples = []
  const channel = createPoseFrameChannel(model, { onFrame: (sample) => samples.push(sample) })
  const initial = frame(1, 2)
  channel.push('physical', initial, { modelId: 'robot', modelSha256: '0'.repeat(64) })
  initial.bodies[1].position[0] = 999
  assert.equal(samples[0].frame.bodies[1].position[0], 2)
  assert.throws(() => channel.push('physical', frame(1, 2)), /strictly increase/u)
  assert.throws(() => channel.push('physical', frame(2, 3), { modelId: 'another-robot' }), /identity/u)
  channel.reset()
  channel.push('physical', frame(0, 0))
  assert.equal(samples.at(-1).frame.time_s, 0)
  channel.dispose()
  assert.throws(() => channel.push('physical', frame(1, 1)), /disposed/u)
})
