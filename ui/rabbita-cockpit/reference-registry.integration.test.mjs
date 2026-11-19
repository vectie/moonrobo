import test from 'node:test'
import assert from 'node:assert/strict'
import { inspectLearningPhysics, pairLearningTrial, learningTraceSVG, learningTrialQuality } from './learning-experiments.js'
import { validatePoseReplay, createReplaySampler } from './viewer/pose-replay-channel.js'

const host = process.env.MOONROBO_REFERENCE_HOST
test('registered experiments identify their robot and both archived viewers use the same G1 model', { skip: !host }, async () => {
  const { experimentsForRobot, assertRobotReplay } = await import('./robot-context.js')
  const listing = await (await fetch(`${host}/api/moondata/learning-experiments`)).json()
  const g1 = experimentsForRobot(listing, 'g1-simulation')
  assert.equal(g1.length, listing.experiments.length)
  assert.equal(experimentsForRobot(listing, 'noetix-e1-lab-01').length, 0)
  const hashes = new Set()
  for (const id of listing.replay_experiment_ids) {
    assert.equal(listing.experiment_robot_ids[id], 'g1-simulation')
    const replay = assertRobotReplay(validatePoseReplay(await (await fetch(`${host}/api/moondata/learning-experiments/${id}/replay`)).json()), 'g1-simulation')
    hashes.add(replay.model.sha256)
  }
  assert.equal(hashes.size, 1)
})
test('native replay JSON opens with root None omitted and a sealed mesh per replay resolves', { skip: !host }, async () => {
  const listing = await (await fetch(`${host}/api/moondata/learning-experiments`)).json()
  for (const id of listing.replay_experiment_ids) {
    const response = await fetch(`${host}/api/moondata/learning-experiments/${id}/replay`)
    assert.equal(response.ok, true)
    const replay = validatePoseReplay(await response.json())
    assert.equal(replay.experiment_id, id)
    for (const clip of replay.clips) {
      const sampler = createReplaySampler(clip)
      assert.ok(sampler.sample(sampler.startTime).length > 0)
      assert.ok(sampler.sample(sampler.endTime).length > 0)
    }
    const mesh = replay.model.visuals.find(value => value.geometry.kind === 'mesh').geometry
    const asset = await fetch(`${host}/api/moondata/learning-experiments/${id}/replay-assets/${mesh.sha256}`)
    assert.equal(asset.ok, true)
    const { createHash } = await import('node:crypto')
    assert.equal(createHash('sha256').update(new Uint8Array(await asset.arrayBuffer())).digest('hex'), mesh.sha256)
  }
})
test('registered reference experiments pair all origins and retain full planned curves through the live API', { skip: !host }, async () => {
  for (const id of ['reference-joint-initialization', 'reference-feedforward-initialization']) {
    for (const seed of [0, 1, 2]) {
      const response = await fetch(`${host}/api/moondata/learning-experiments/${id}/physics/${seed}`)
      assert.equal(response.ok, true)
      const evidence = inspectLearningPhysics(await response.json(), id, seed)
      assert.equal(evidence.report.candidate.trials.length, 27)
      const cells = new Set()
      for (let i = 0; i < 27; i++) {
        const pair = pairLearningTrial(evidence.report, i), trial = pair.candidate
        assert.ok(pair.baseline)
        assert.equal(pair.baseline.reference_start_step, trial.reference_start_step)
        assert.equal(trial.requested_seconds, 30 - trial.reference_start_step * .02)
        assert.equal(trial.reference_replay.length, Math.round(trial.requested_seconds / .02))
        cells.add(`${trial.case_id}:${trial.reference_start_step}`)
        const svg = learningTraceSVG(pair, 'root_height_m', 'Root height', 0)
        assert.match(svg, /le-reference/)
        assert.doesNotMatch(svg, /NaN|Infinity/)
        assert.ok(trial.replay.every(frame => Number.isFinite(frame.body_position_error_m)))
      }
      assert.equal(cells.size, 27)
      assert.equal(evidence.physical_execution_allowed, false)
    }
  }
})

test('registered reset/state-origin policies keep partial trial passes separate from policy qualification', { skip: !host }, async () => {
  for (const id of ['reference-reset-origin', 'reference-trajectory-origin']) {
    for (const seed of [0, 1, 2]) {
      const response = await fetch(`${host}/api/moondata/learning-experiments/${id}/physics/${seed}`)
      assert.equal(response.ok, true)
      const evidence = inspectLearningPhysics(await response.json(), id, seed)
      const trials = evidence.report.candidate.trials
      assert.equal(trials.length, 27)
      const passing = trials.filter(trial => learningTrialQuality(evidence.report, trial).passed)
      assert.equal(passing.length, id === 'reference-trajectory-origin' && seed === 2 ? 2 : 0)
      assert.equal(evidence.report.candidate.quality.quality_passed, false)
      for (const trial of passing) { assert.equal(trial.reference_start_step, 1000); assert.equal(trial.requested_seconds, 10) }
      for (let i = 0; i < 27; i++) assert.ok(pairLearningTrial(evidence.report, i).baseline)
      if (id === 'reference-trajectory-origin') assert.match(evidence.report.baseline_role, /reset-only trained/)
      assert.ok(trials.every(trial => trial.replay.every(frame => Number.isFinite(frame.root_orientation_error_rad))))
    }
  }
})

test('registered six-cycle replay comparison keeps full-duration passes and inaccurate completions distinct', { skip: !host }, async () => {
  const expected = { 'reference-recent-replay': [0, 5, 0], 'reference-anchor-replay': [3, 9, 0] }
  const sources = {}
  const recent = {}
  for (const [id, counts] of Object.entries(expected)) {
    for (const seed of [0, 1, 2]) {
      const response = await fetch(`${host}/api/moondata/learning-experiments/${id}/physics/${seed}`)
      assert.equal(response.ok, true)
      const evidence = inspectLearningPhysics(await response.json(), id, seed)
      const report = evidence.report, trials = report.candidate.trials
      assert.equal(trials.length, 27)
      const passing = trials.filter(trial => learningTrialQuality(report, trial).passed)
      assert.equal(passing.length, counts[seed])
      assert.equal(report.candidate.quality.quality_passed, false)
      assert.equal(report.training.cycles, 6)
      assert.equal(report.training.model_replay_window_capacity, 20000)
      assert.equal(report.training.physical_records_new, 324)
      assert.equal(report.training.physical_records_reused, 603)
      assert.equal(evidence.physical_execution_allowed, false)
      sources[id] = report.training.source_study_sha256
      for (let i = 0; i < 27; i++) {
        const pair = pairLearningTrial(report, i)
        assert.ok(pair.baseline)
        assert.equal(pair.baseline.reference_start_step, pair.candidate.reference_start_step)
        assert.equal(pair.candidate.reference_replay.length, Math.round(pair.candidate.requested_seconds / .02))
      }
      if (id === 'reference-anchor-replay') {
        assert.deepEqual(report.baseline.summary, recent[seed].candidate.summary)
        assert.deepEqual(report.baseline.trials.map(t => t.episode_id), recent[seed].candidate.trials.map(t => t.episode_id))
        assert.match(report.baseline_role, /six-cycle recent-FIFO/)
        assert.equal(report.training.model_replay_mode, 'initial-anchor')
        assert.ok(report.training.initial_anchor_windows > 6000)
        if (seed === 1) assert.equal(passing.filter(t => t.reference_start_step === 0 && t.simulated_seconds === 30).length, 3)
        if (seed === 2) assert.equal(trials.filter(t => !t.failed).length, 16)
      } else { assert.equal(report.training.model_replay_mode, 'recent-fifo'); recent[seed] = report }
    }
  }
  assert.equal(sources['reference-recent-replay'], sources['reference-anchor-replay'])
})
