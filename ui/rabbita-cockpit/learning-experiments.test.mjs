import test from 'node:test'
import assert from 'node:assert/strict'
import { inspectLearningExperiments, inspectLearningPhysics, pairLearningTrial, learningObservation, learningTraceSVG, learningTrialQuality, mountLearningExperiments } from './learning-experiments.js'

const frame = (time_s, root_height_m = .7) => ({ time_s, root_height_m, upright_z: .8, contacts: 2 })
const trial = (seed, replay = [frame(.02), frame(.04)]) => ({ case_id: 'stand', seed, failed: true, end_reason: 'fall', simulated_seconds: replay.at(-1).time_s, joint_rmse_rad: .12, replay })
const stats = { trials: 1, falls: 1, mean_survival_s: .04, mean_joint_rmse_rad: .12 }
const reference = { uri: 'moondata://blobs/sha256/ab/abcdef', checksum: 'sha256:abcdef' }
const candidate = { seed: 0, selected_update: 100, baseline: stats, candidate: stats, producer_qualified: false, checkpoint_ref: reference }
const experiment = id => ({ format: 'moonrobo.learning-experiment.v1', experiment_id: id, physical_execution_allowed: false, candidates: [candidate] })
const listing = { experiments: [experiment('first'), experiment('warm')], physical_execution_allowed: false }
const physics = id => ({ format: 'moonrobo.learning-physics.v1', experiment_id: id, seed: 0, data_ref: reference, physical_execution_allowed: false,
  report: { baseline: { trials: [trial(20)] }, candidate: { trials: [trial(20, [frame(.02), frame(.04), frame(.06, .4)])] } } })

test('physics pairing follows case and evaluation seed, including absent baseline observations', () => {
  const payload = physics('warm')
  payload.report.baseline.trials.unshift(trial(21))
  const report = inspectLearningPhysics(payload, 'warm', 0).report
  const pair = pairLearningTrial(report, 0)
  assert.equal(pair.baseline.seed, 20)
  assert.equal(learningObservation(pair.baseline, .06), null)
  assert.equal(learningObservation(pair.baseline, .03), null)
  assert.equal(learningObservation(pair.baseline, .04).time_s, .04)
  report.baseline.trials = []
  assert.equal(pairLearningTrial(report, 0).baseline, null)
})

test('evidence checks selection binding and chronology before plotting', () => {
  assert.equal(inspectLearningExperiments(listing).length, 2)
  assert.throws(() => inspectLearningExperiments({ ...listing, physical_execution_allowed: true }))
  assert.throws(() => inspectLearningPhysics(physics('first'), 'warm', 0), /match/)
  const payload = physics('warm')
  payload.report.candidate.trials[0].replay[1].time_s = .02
  assert.throws(() => inspectLearningPhysics(payload, 'warm', 0), /sample/)
  const pair = pairLearningTrial(physics('warm').report, 0)
  const svg = learningTraceSVG(pair, 'root_height_m', 'Root height (m)', 2)
  assert.match(svg, /Baseline ended: fall at 0.04 s/)
  assert.match(svg, /Candidate ended: fall at 0.06 s/)
  assert.doesNotMatch(svg, /NaN|Infinity/)
})

class Element {
  constructor() { this.listeners = new Map(); this.value = ''; this.disabled = false; this.hidden = false; this.textContent = ''; this.dataset = {} }
  set innerHTML(value) { this.markup = value }
  addEventListener(type, fn) { this.listeners.set(type, fn) }
  async dispatch(type) { if (!(this.disabled && type === 'click')) await this.listeners.get(type)?.({ target: this }) }
  replaceChildren(...values) { this.children = values; if (values.length) this.value = values[0].value }
  setAttribute() {}
  focus() { this.focused = true }
  showModal() { this.open = true }
  close() { this.open = false; this.listeners.get('close')?.() }
}
function harness(responses, options = {}) {
  const root = new Element(), dialog = new Element(), elements = new Map(), requests = []
  root.ownerDocument = { createElement: () => new Element(), addEventListener() {} }
  root.querySelector = selector => { if (!elements.has(selector)) elements.set(selector, new Element()); return elements.get(selector) }
  const api = mountLearningExperiments({ root, dialog, ...options, hostUrl: 'https://host.invalid/book/', fetchImpl: async (url, options) => {
    requests.push({ url, ...options }); const response = responses.shift(); if (response instanceof Error) throw response
    const payload = typeof response === 'function' ? await response() : response
    return { ok: true, json: async () => payload }
  } })
  return { root, dialog, api, requests, el: name => root.querySelector(`#le-${name}`) }
}

test('workbench compares failed policies and inspects terminal samples using read-only requests', async () => {
  const h = harness([listing, { ...physics('warm'), original_duration_s: 10 }])
  assert.equal(h.requests.length, 0)
  await h.api.refresh(); await h.api.inspect(1, 0)
  assert.match(h.el('comparison').markup, /Not qualified/)
  assert.equal(h.el('inspector').hidden, false)
  assert.match(h.el('scope').textContent, /Maximum trial duration: 10 s/)
  assert.equal(h.el('evaluation').children[0].textContent, 'Original 10 s trials')
  await h.el('end').dispatch('click')
  assert.match(h.el('observation').textContent, /Baseline: no observation at this time/)
  assert.equal(h.el('next').disabled, true)
  assert.match(h.el('provenance').textContent, /Physics checksum: sha256:abcdef/)
  assert.ok(h.requests.every(request => request.method === 'GET' && !request.body))
  assert.equal(h.requests[1].url, 'https://host.invalid/book/api/moondata/learning-experiments/warm/physics/0')
})

test('experiment selection avoids an all-candidates wall and retains aligned records', async () => {
  const aligned = { ...experiment('aligned'), candidates: [] }
  const h = harness([{ ...listing, experiments: [...listing.experiments, aligned] }])
  await h.api.refresh()
  h.api.selectExperiment('warm')
  assert.match(h.el('comparison').markup, /Inspect warm training seed/)
  assert.doesNotMatch(h.el('comparison').markup, /Inspect first training seed/)
  h.api.selectExperiment('aligned')
  assert.match(h.el('comparison').markup, /full-motion evaluation/)
  assert.equal(h.el('inspector').hidden, true)
})

test('embedded evidence loads without a dialog and returns the live replay inventory', async () => {
  const h = harness([{ ...listing, replay_experiment_ids: ['warm'] }, physics('warm')], { dialog: null, embedded: true })
  const registry = await h.api.refresh()
  assert.deepEqual(registry.replayIds, ['warm'])
  h.api.selectExperiment('warm')
  await h.api.inspect(1, 0)
  assert.equal(h.el('panel-inspect').hidden, false)
  assert.equal(h.el('inspector').hidden, false)
  assert.equal(h.el('selection').textContent, '候选 0 · 轨迹')
  assert.ok(h.requests.every(request => request.method === 'GET' && !request.body))
})

test('robot-scoped inspector excludes foreign experiments and fails closed without source ownership', async () => {
  const h = harness([{ ...listing, experiment_robot_ids: { warm: 'g1-simulation', first: 'noetix-e1-lab-01' } }, listing], { dialog: null, embedded: true, robotId: 'g1-simulation' })
  const registered = await h.api.refresh()
  assert.deepEqual(registered.experiments.map(value => value.experiment_id), ['warm'])
  assert.doesNotMatch(h.el('comparison').markup, /Inspect first/)
  const unavailable = await h.api.refresh()
  assert.equal(unavailable.experiments.length, 0)
  assert.doesNotMatch(h.el('comparison').markup, /Inspect warm/)
})

test('switching candidates ignores late evidence and a failed refresh clears the old inspector', async () => {
  let resolve
  const delayed = new Promise(done => { resolve = done })
  const h = harness([listing, () => delayed, physics('warm'), new Error('Host unavailable')])
  await h.api.refresh()
  const first = h.api.inspect(0, 0)
  await h.api.inspect(1, 0)
  resolve(physics('first')); await first
  assert.equal(h.el('selection').textContent, 'warm · training seed 0')
  await h.api.refresh()
  assert.equal(h.el('inspector').hidden, true)
  assert.match(h.el('status').textContent, /Host unavailable/)
  assert.equal(h.el('comparison').textContent, 'Experiment list unavailable.')
})

test('a short reported pass keeps extended failures visible and loads their own recorded trace', async () => {
  const original = physics('warm')
  original.followup = { format: 'moonrobo.g1-candidate-followup.v1', physical_execution_allowed: false, original_duration_s: 2,
    candidates: [{ seed: 0, evaluations: [{ mode: 'fresh-ten-second', summary: { trials: 1, falls: 1, mean_survival_s: .06 } }] }] }
  const extended = structuredClone(original)
  extended.evaluation_mode = 'fresh-ten-second'
  const h = harness([listing, original, extended])
  await h.api.refresh(); await h.api.inspect(1, 0)
  assert.match(h.el('scope').textContent, /2 s trials only/)
  assert.match(h.el('scope').textContent, /Extended 10 s trials: 1\/1 falls/)
  h.el('evaluation').value = 'fresh-ten-second'
  await h.el('evaluation').dispatch('change'); await h.api.whenIdle()
  assert.equal(h.el('evaluation').value, 'fresh-ten-second')
  assert.match(h.requests.at(-1).url, /\/warm\/physics\/0\/fresh-ten-second$/)
  assert.match(h.el('provenance').textContent, /Evaluation: Extended 10 s trials/)
  assert.throws(() => inspectLearningPhysics(original, 'warm', 0, 'fresh-ten-second'), /match/)
})

test('reference trials pair by origin and keep planned remainder visible after a fall', async () => {
  const payload = physics('warm')
  payload.report.evaluation_protocol = { kind: 'reference-remainder', clip_duration_s: 30, origins_s: [0, 10, 20] }
  payload.report.candidate.trials = [0, 500, 1000].map((origin, index) => ({ ...trial(7300), reference_start_step: origin,
    reference_start_time_s: index * 10, requested_seconds: 30 - index * 10,
    body_position_rmse_m: .001, root_position_rmse_m: .002, root_orientation_rmse_rad: .003,
    reference_replay: [frame(.02), frame(30 - index * 10)] }))
  payload.report.baseline.trials = payload.report.candidate.trials.map(value => ({ ...value })).reverse()
  inspectLearningPhysics(payload, 'warm', 0)
  assert.equal(pairLearningTrial(payload.report, 1).baseline.reference_start_step, 500)
  const svg = learningTraceSVG(pairLearningTrial(payload.report, 1), 'root_height_m', 'Height', 0)
  assert.match(svg, /le-reference/)
  assert.match(svg, /Reference ended: reference_end at 20 s/)
  const h = harness([listing, payload])
  await h.api.refresh(); await h.api.inspect(1, 0)
  assert.match(h.el('evaluation').children[0].textContent, /30\/20\/10 s/)
  assert.match(h.el('scope').textContent, /remaining durations 30\/20\/10 s/)
  h.el('trial').value = '1'; await h.el('trial').dispatch('change')
  assert.match(h.el('trial-summary').textContent, /reference origin 10.000 s · requested 20.000 s/)
  assert.match(h.el('trial-summary').textContent, /body RMSE 0.0010 m/)
  assert.equal(h.el('reference-legend').hidden, false)
  assert.match(h.el('observation').textContent, /Reference: height/)
  payload.report.candidate.trials[1].reference_replay.at(-1).time_s = 19
  assert.throws(() => inspectLearningPhysics(payload, 'warm', 0), /Incomplete planned/)
})

test('individual tracking quality distinguishes completion, limits and the full policy gate', async () => {
  const payload = physics('warm')
  payload.report.evaluation_protocol = { kind: 'reference-remainder', clip_duration_s: 30, origins_s: [20] }
  payload.report.tracking_quality_target = { maximum_per_trial: { joint_rmse_rad: .03, body_position_rmse_m: .05, root_position_rmse_m: .05, root_orientation_rmse_rad: .1 } }
  const completed = { ...trial(7300), reference_start_step: 1000, reference_start_time_s: 20, requested_seconds: 10,
    simulated_seconds: 10, failed: false, end_reason: 'time_limit', replay: [frame(.02), frame(10)],
    joint_rmse_rad: .02, body_position_rmse_m: .03, root_position_rmse_m: .04, root_orientation_rmse_rad: .06,
    reference_replay: [frame(.02), frame(10)] }
  const inaccurate = { ...completed, case_id: 'inaccurate', root_orientation_rmse_rad: .15 }
  const fallen = { ...completed, case_id: 'fall', failed: true, end_reason: 'fall' }
  payload.report.candidate.trials = [fallen, inaccurate, completed]
  payload.report.baseline.trials = structuredClone(payload.report.candidate.trials)
  assert.equal(learningTrialQuality(payload.report, completed).passed, true)
  assert.deepEqual(learningTrialQuality(payload.report, inaccurate).failures, ['root_orientation_rmse_rad'])
  assert.equal(learningTrialQuality(payload.report, fallen).passed, false)
  assert.equal(learningTrialQuality({ ...payload.report, tracking_quality_target: { maximum_per_trial: {} } }, completed), null)
  const h = harness([listing, payload])
  await h.api.refresh(); await h.api.inspect(1, 0)
  assert.match(h.el('quality-summary').textContent, /1\/3 individual trials.*Full recorded suite: not qualified/)
  assert.match(h.el('comparison').markup, /Not qualified/)
  await h.el('first-passing').dispatch('click')
  assert.equal(h.el('trial').value, '2')
  assert.match(h.el('trial-quality').textContent, /meets the fixed tracking limits.*not qualified/)
  h.el('trial').value = '1'; await h.el('trial').dispatch('change')
  assert.match(h.el('trial-quality').textContent, /root angle RMSE/)
})
