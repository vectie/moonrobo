const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const number = (value, digits = 3) => Number.isFinite(value) ? value.toFixed(digits) : 'Unavailable'
const trialKey = trial => JSON.stringify([trial.case_id, trial.seed, trial.reference_start_step ?? null])
const originLabel = trial => trial.reference_start_step == null ? '' : ` · reference origin ${number(trial.reference_start_time_s)} s · requested ${number(trial.requested_seconds)} s`
const qualityLabels = { completion: 'full duration', joint_rmse_rad: 'joint RMSE', body_position_rmse_m: 'body position RMSE', root_position_rmse_m: 'root position RMSE', root_orientation_rmse_rad: 'root angle RMSE' }

export function learningTrialQuality(report, trial) {
  const limits = report.tracking_quality_target?.maximum_per_trial
  if (report.evaluation_protocol?.kind !== 'reference-remainder' || !limits) return null
  if (Object.keys(qualityLabels).filter(key => key !== 'completion').some(key => !Number.isFinite(limits[key]) || limits[key] < 0)) return null
  const failures = []
  if (trial.failed || trial.end_reason === 'fall' || !Number.isFinite(trial.requested_seconds) || !Number.isFinite(trial.simulated_seconds) || Math.abs(trial.simulated_seconds - trial.requested_seconds) > 1e-9) failures.push('completion')
  for (const [metric, limit] of Object.entries(limits)) {
    if (!Number.isFinite(limit) || !Number.isFinite(trial[metric]) || trial[metric] > limit) failures.push(metric)
  }
  return { passed: failures.length === 0, failures }
}

export function inspectLearningExperiments(payload) {
  if (payload?.physical_execution_allowed !== false || !Array.isArray(payload.experiments)) throw new Error('Learning experiment list is unavailable.')
  for (const experiment of payload.experiments) {
    if (experiment.format !== 'moonrobo.learning-experiment.v1' || experiment.physical_execution_allowed !== false || !Array.isArray(experiment.candidates)) throw new Error('Unsupported experiment summary.')
  }
  return payload.experiments
}

export function inspectLearningPhysics(payload, experimentId, seed, mode = 'original') {
  if (payload?.format !== 'moonrobo.learning-physics.v1' || payload.experiment_id !== experimentId || payload.seed !== seed || (payload.evaluation_mode || 'original') !== mode || payload.physical_execution_allowed !== false || !payload.data_ref?.checksum) throw new Error('Physics evidence does not match the selected candidate and evaluation.')
  if (payload.followup != null && (payload.followup.format !== 'moonrobo.g1-candidate-followup.v1' || payload.followup.physical_execution_allowed !== false || !Array.isArray(payload.followup.candidates))) throw new Error('Unsupported follow-up evidence.')
  if (payload.original_duration_s != null && (!Number.isFinite(payload.original_duration_s) || payload.original_duration_s <= 0)) throw new Error('Invalid original evaluation duration.')
  for (const group of ['baseline', 'candidate']) {
    const trials = payload.report?.[group]?.trials
    if (!Array.isArray(trials)) throw new Error(`Missing ${group} trials.`)
    const keys = new Set()
    for (const trial of trials) {
      const key = trialKey(trial)
      if (trial.reference_start_step != null && (!Number.isInteger(trial.reference_start_step) || trial.reference_start_step < 0)) throw new Error('Invalid reference origin.')
      if (keys.has(key) || !Array.isArray(trial.replay) || !trial.replay.length) throw new Error('Missing or ambiguous recorded trial.')
      keys.add(key)
      let time = -Infinity
      for (const frame of trial.replay) {
        if (!Number.isFinite(frame.time_s) || frame.time_s <= time || !Number.isFinite(frame.root_height_m) || !Number.isFinite(frame.upright_z) || !Number.isFinite(frame.contacts)) throw new Error('Invalid recorded physics sample.')
        time = frame.time_s
      }
      if (group === 'candidate' && payload.report.evaluation_protocol?.kind === 'reference-remainder') {
        if (!Array.isArray(trial.reference_replay) || !trial.reference_replay.length || !Number.isFinite(trial.requested_seconds)) throw new Error('Missing planned reference remainder.')
        let previous = -Infinity
        for (const frame of trial.reference_replay) {
          if (!Number.isFinite(frame.time_s) || frame.time_s <= previous || !Number.isFinite(frame.root_height_m) || !Number.isFinite(frame.upright_z)) throw new Error('Invalid planned reference sample.')
          previous = frame.time_s
        }
        if (Math.abs(previous - trial.requested_seconds) > 1e-9) throw new Error('Incomplete planned reference remainder.')
      }
    }
  }
  if (!payload.report.candidate.trials.length) throw new Error('No candidate trials were recorded.')
  return payload
}

// Match the physical condition and reference origin, never report array order.
export function pairLearningTrial(report, index) {
  const candidate = report.candidate.trials[index]
  if (!candidate) throw new Error('Select a recorded trial.')
  return { candidate, baseline: report.baseline.trials.find(trial => trialKey(trial) === trialKey(candidate)) || null }
}

export function learningObservation(trial, time) {
  return trial?.replay.find(frame => Math.abs(frame.time_s - time) < 1e-9) || null
}

export function learningTraceSVG(pair, channel, label, cursor) {
  const tracks = [pair.baseline && { trial: pair.baseline, name: 'Baseline', style: 'le-baseline' }, { trial: pair.candidate, name: 'Candidate', style: 'le-candidate' }].filter(Boolean)
  const reference = pair.candidate.reference_replay
  if (reference?.length && reference.every(frame => Number.isFinite(frame[channel]))) tracks.push({ trial: { replay: reference, end_reason: 'reference_end' }, name: 'Reference', style: 'le-reference' })
  const frames = tracks.flatMap(({ trial }) => trial.replay)
  let min = Math.min(...frames.map(frame => frame[channel])), max = Math.max(...frames.map(frame => frame[channel]))
  const padding = (max - min || Math.max(Math.abs(max), 1)) * 0.12
  min -= padding; max += padding
  const end = Math.max(...frames.map(frame => frame.time_s))
  const x = t => 4 + (end > 0 ? t / end : 0) * 688
  const y = value => 176 - (value - min) / (max - min) * 168
  const lines = tracks.map(({ trial, name, style }) => {
    const points = trial.replay.map(frame => `${x(frame.time_s)},${y(frame[channel])}`).join(' ')
    const last = trial.replay.at(-1)
    return `<polyline class="${style}" points="${points}"/><circle class="${style}-end" cx="${x(last.time_s)}" cy="${y(last[channel])}" r="4"><title>${name} ended: ${escape(trial.end_reason)} at ${last.time_s} s</title></circle>`
  }).join('')
  const current = pair.candidate.replay[cursor]
  return `<figure><figcaption>${escape(label)}</figcaption><div class="le-chart-body"><div class="le-y-axis"><span>${number(max)}</span><span>${number(min)}</span></div><svg viewBox="0 0 700 184" preserveAspectRatio="none" role="img" aria-label="${escape(label)} by simulated time; dashed baseline and solid candidate"><path class="le-axis" d="M 4 8 V 176 H 696"/>${lines}<path class="le-cursor" d="M ${x(current.time_s)} 8 V 176"/></svg></div><div class="le-chart-scale"><span>0 s</span><span>${number(end)} s</span></div></figure>`
}

import { toolTabs, selectToolTab } from './tool-tabs.js'

export function mountLearningExperiments({ root, dialog, embedded = false, hostUrl = '', fetchImpl = globalThis.fetch.bind(globalThis), robotId = '' }) {
  if (!root || (!dialog && !embedded)) return null
  root.setAttribute('data-tool-workspace', '')
  root.innerHTML = `<header class="digital-trials-heading"><div><p class="eyebrow">MoonData / Learning</p><h2 id="learning-experiments-title">Learning experiments</h2></div><button id="le-close" type="button">Close</button></header>
    <div class="le-toolbar"><span class="le-recorded-badge">Recorded simulation</span><a href="./results.html">Results overview ↗</a><button id="le-refresh" type="button" aria-label="Refresh experiments" title="Refresh experiments"><span class="robo-glyph glyph-refresh" aria-hidden="true"></span></button></div>
    ${toolTabs('le', [['compare', 'Compare', 'compare'], ['inspect', 'Trial', 'telemetry'], ['replay', '3D replay', 'replay']])}
    <p id="le-status" role="status" aria-live="polite">Open to load registered experiments.</p>
    <section id="le-panel-compare" role="tabpanel" aria-labelledby="le-tab-compare">
    <label for="le-experiment">Experiment</label><select id="le-experiment"></select>
    <div id="le-comparison" class="le-table-wrap" tabindex="0" aria-label="Experiment comparison"></div>
    </section>
    <section id="le-panel-inspect" role="tabpanel" aria-labelledby="le-tab-inspect" hidden>
    <p id="le-empty-inspector">${embedded ? '' : 'Choose a candidate in Compare to inspect its trials.'}</p>
    <section id="le-inspector" hidden aria-labelledby="le-selection"><h3 id="le-selection"></h3>
      <label for="le-evaluation">Recorded evaluation</label><select id="le-evaluation"></select><details><summary>评测范围</summary><p id="le-scope"></p></details>
      <p id="le-quality-summary" hidden></p><button id="le-first-passing" type="button" aria-controls="le-trial" hidden>Inspect first trial meeting limits</button>
      <label for="le-trial">Recorded trial</label><select id="le-trial"></select>
      <details><summary>试验详情</summary><p id="le-trial-summary"></p></details><p id="le-trial-quality" role="status" hidden></p><p class="le-legend"><span class="le-baseline-key">Dashed: baseline physics</span><span class="le-candidate-key">Solid: candidate physics</span><span id="le-reference-legend" class="le-reference-key" hidden>Dotted: planned reference</span></p>
      <div id="le-plots" class="le-plots"></div>
      <details><summary>How to read the chart</summary><p id="le-track-note">Simulated time from reset. Lines connect recorded observations and stop when each trial ends. Reference and world-model tracks are not included in this report.</p></details>
      <div class="le-toolbar"><button id="le-prev" type="button">Previous sample</button><button id="le-next" type="button">Next sample</button><button id="le-end" type="button">Last sample</button></div>
      <label for="le-cursor">Candidate observation</label><input id="le-cursor" type="range" min="0" max="0" step="1">
      <details><summary>Sample details</summary><p id="le-observation" role="status" aria-live="polite"></p></details>
      <details><summary>Evidence and checkpoint references</summary><pre id="le-provenance"></pre></details>
    </section></section>
    <section id="le-panel-replay" role="tabpanel" aria-labelledby="le-tab-replay" hidden><div id="le-replay-mount"></div></section>`
  const el = name => root.querySelector(`#le-${name}`)
  let experiments = [], evidence = null, active = null, cursor = 0, generation = 0, pending = Promise.resolve(), opener = null
  const apiUrl = path => `${hostUrl.replace(/\/$/, '')}/api/moondata/learning-experiments${path}`
  async function get(path) {
    const response = await fetchImpl(apiUrl(path), { method: 'GET' })
    if (!response.ok) throw new Error(`Cannot read registered evidence (HTTP ${response.status}).`)
    return response.json()
  }
  function clearInspection() { evidence = null; active = null; el('inspector').hidden = true; el('empty-inspector').hidden = false; el('plots').replaceChildren(); el('provenance').textContent = ''; el('scope').textContent = ''; el('quality-summary').hidden = true; el('first-passing').hidden = true; el('trial-quality').hidden = true }
  function renderComparison() {
    const ei = Math.max(0, experiments.findIndex(value => value.experiment_id === el('experiment').value))
    const experiment = experiments[ei]
    if (!experiment) { el('comparison').innerHTML = '<p>No learning experiments are registered in this workspace.</p>'; return }
    if (!experiment.candidates.length) {
      el('comparison').innerHTML = `<p>This experiment uses a full-motion evaluation. <a href="./results.html?evaluation=${encodeURIComponent(experiment.experiment_id)}#motions">View the recorded results ↗</a></p>`
      return
    }
    el('comparison').innerHTML = `<table><caption>Baseline → candidate · recorded simulation</caption><thead><tr><th scope="col">Seed</th><th scope="col">Survival, s</th><th scope="col">Falls / trials</th><th scope="col">Joint RMSE, rad</th><th scope="col">Result</th><th scope="col">Trials</th></tr></thead><tbody>${experiment.candidates.map((candidate, ci) => `<tr><th scope="row">${escape(candidate.seed)}</th><td>${number(candidate.baseline.mean_survival_s)} → ${number(candidate.candidate.mean_survival_s)}</td><td>${escape(candidate.candidate.falls)} / ${escape(candidate.candidate.trials)}</td><td>${number(candidate.baseline.mean_joint_rmse_rad, 4)} → ${number(candidate.candidate.mean_joint_rmse_rad, 4)}</td><td><span class="${candidate.producer_qualified ? 'le-reported-pass' : 'le-failed'}">${candidate.producer_qualified ? 'Provider reports pass' : 'Not qualified'}</span></td><td><button type="button" data-experiment="${ei}" data-candidate="${ci}" aria-label="Inspect ${escape(experiment.experiment_id)} training seed ${escape(candidate.seed)} trials">Inspect trials</button></td></tr>`).join('')}</tbody></table>`
  }
  function renderTrial() {
    if (!evidence) return
    const pair = pairLearningTrial(evidence.report, Number(el('trial').value)), trial = pair.candidate
    cursor = Math.min(cursor, trial.replay.length - 1)
    const frame = trial.replay[cursor], baseline = learningObservation(pair.baseline, frame.time_s)
    const describe = sample => sample ? `height ${number(sample.root_height_m)} m; upright Z ${number(sample.upright_z)}; contacts ${sample.contacts}` : 'no observation at this time (not interpolated)'
    const tracking = Number.isFinite(trial.body_position_rmse_m) ? ` · body RMSE ${number(trial.body_position_rmse_m, 4)} m · root position RMSE ${number(trial.root_position_rmse_m, 4)} m · root angle RMSE ${number(trial.root_orientation_rmse_rad, 4)} rad` : ''
    el('trial-summary').textContent = `Case ${trial.case_id} · evaluation seed ${trial.seed}${originLabel(trial)} · candidate ended: ${trial.end_reason} at ${number(trial.simulated_seconds)} s · joint RMSE ${number(trial.joint_rmse_rad, 4)} rad${tracking}. Baseline: ${pair.baseline ? `${pair.baseline.end_reason} at ${number(pair.baseline.simulated_seconds)} s` : 'unavailable'}.`
    const quality = learningTrialQuality(evidence.report, trial)
    el('trial-quality').hidden = !quality
    if (quality) {
      el('trial-quality').className = quality.passed ? 'le-reported-pass' : 'le-failed'
      const suite = experiments[active.ei].candidates[active.ci].producer_qualified ? 'provider reports pass' : 'not qualified'
      el('trial-quality').textContent = quality.passed ? `Individual trial meets the fixed tracking limits. Full recorded suite: ${suite}.` : `Individual trial does not meet: ${quality.failures.map(key => qualityLabels[key] || key).join(', ')}.`
      if (embedded) el('trial-quality').textContent = quality.passed ? `本条轨迹达标 · 完整候选${experiments[active.ei].candidates[active.ci].producer_qualified ? '记录达标' : '未达标'}` : `本条轨迹未达标 · ${quality.failures.length} 项未满足跟踪限值`
    }
    el('plots').innerHTML = learningTraceSVG(pair, 'root_height_m', 'Root height (m)', cursor) + learningTraceSVG(pair, 'upright_z', 'Root upright Z (unitless)', cursor)
    for (const [channel, label] of [['root_position_error_m', 'Root position error (m)'], ['body_position_error_m', 'Body position error (m)'], ['root_orientation_error_rad', 'Root angle error (rad)']]) {
      if ([pair.baseline, pair.candidate].filter(Boolean).every(value => value.replay.every(sample => Number.isFinite(sample[channel])))) el('plots').innerHTML += learningTraceSVG(pair, channel, label, cursor)
    }
    el('reference-legend').hidden = !trial.reference_replay?.length
    el('track-note').textContent = trial.reference_replay?.length ? 'Time from the restored origin. Physics stops at each trial end; the planned reference continues to its full remainder. World-model predictions are not included.' : 'Simulated time from reset. Lines connect recorded observations and stop when each trial ends. Reference and world-model tracks are not included in this report.'
    el('cursor').max = String(trial.replay.length - 1); el('cursor').value = String(cursor)
    el('prev').disabled = cursor === 0; el('next').disabled = cursor === trial.replay.length - 1; el('end').disabled = el('next').disabled
    const planned = learningObservation({ replay: trial.reference_replay || [] }, frame.time_s)
    el('observation').textContent = `Observation ${cursor + 1}/${trial.replay.length} · ${number(frame.time_s)} s. Candidate: ${describe(frame)}. Baseline: ${describe(baseline)}.${planned ? ` Reference: height ${number(planned.root_height_m)} m; upright Z ${number(planned.upright_z)}.` : ''}`
  }
  async function inspect(ei, ci, mode = 'original') {
    const experiment = experiments[ei], candidate = experiment?.candidates[ci]
    if (!candidate) return
    const token = ++generation
    clearInspection(); el('status').textContent = `Loading ${experiment.experiment_id}, training seed ${candidate.seed}…`
    try {
      const suffix = mode === 'original' ? '' : `/${encodeURIComponent(mode)}`
      const result = inspectLearningPhysics(await get(`/${encodeURIComponent(experiment.experiment_id)}/physics/${candidate.seed}${suffix}`), experiment.experiment_id, candidate.seed, mode)
      if (token !== generation) return
      evidence = result; active = { ei, ci }; cursor = 0
      const followup = evidence.followup?.candidates.find(value => value.seed === candidate.seed)
      const originalDuration = evidence.original_duration_s ?? evidence.followup?.original_duration_s
      const protocol = evidence.report.evaluation_protocol
      const remainders = protocol?.kind === 'reference-remainder' ? protocol.origins_s.map(origin => protocol.clip_duration_s - origin) : null
      const labels = { 'original': remainders ? `Reference remainders (${remainders.join('/')} s)` : originalDuration ? `Original ${originalDuration} s trials` : 'Original recorded trials', 'repeat-two-second': 'Repeat 2 s trials', 'fresh-two-second': 'Fresh 2 s trials', 'fresh-ten-second': 'Extended 10 s trials' }
      const modes = ['original', ...(followup?.evaluations || []).map(value => value.mode).filter(value => value in labels)]
      el('evaluation').replaceChildren(...modes.map(value => { const option = root.ownerDocument.createElement('option'); option.value = value; option.textContent = labels[value]; return option }))
      el('evaluation').value = mode
      el('scope').textContent = followup ? `Original reported pass applies to ${originalDuration} s trials only. Follow-up: ${followup.evaluations.map(value => `${labels[value.mode] || value.mode}: ${value.summary.falls}/${value.summary.trials} falls, mean survival ${number(value.summary.mean_survival_s)} s`).join('; ')}.` : originalDuration ? `Maximum trial duration: ${originalDuration} s. Each recorded trial stops at its fall or time limit. Only the original evaluation is registered.` : 'Only the original recorded trials are registered for this candidate. Their duration does not establish longer-term stability.'
      el('selection').textContent = `${experiment.experiment_id} · training seed ${candidate.seed}`
      if (embedded) el('selection').textContent = `候选 ${candidate.seed} · 轨迹`
      if (remainders) el('scope').textContent = `Known training references · clips ${protocol.clip_duration_s} s · origins ${protocol.origins_s.join('/')} s · remaining durations ${remainders.join('/')} s. Qualification includes each trial's joint, body and root tracking limits.`
      if (evidence.report.baseline_role) el('scope').textContent += ` Baseline: ${evidence.report.baseline_role}.`
      const trials = evidence.report.candidate.trials
      const assessed = trials.map(trial => learningTrialQuality(evidence.report, trial))
      if (assessed.every(Boolean)) {
        const passing = assessed.filter(value => value.passed).length
        el('quality-summary').hidden = false
        el('quality-summary').textContent = `${passing}/${trials.length} individual trials meet all fixed tracking limits. Full recorded suite: ${candidate.producer_qualified ? 'provider reports pass' : 'not qualified'}.`
        if (embedded) el('quality-summary').textContent = `${passing} / ${trials.length} 条轨迹达标 · 完整候选${candidate.producer_qualified ? '记录达标' : '未达标'}`
        el('first-passing').hidden = passing === 0
      }
      el('trial').replaceChildren(...trials.map((trial, index) => { const option = root.ownerDocument.createElement('option'); option.value = String(index); option.textContent = `${trial.case_id} · evaluation seed ${trial.seed}${originLabel(trial)} · ${trial.end_reason}${assessed[index] ? assessed[index].passed ? ' · meets tracking limits' : ' · outside tracking limits' : ''}`; return option }))
      el('trial').value = String(Math.max(0, trials.findIndex(trial => trial.failed)))
      el('provenance').textContent = `Experiment: ${experiment.experiment_id}\nSelected update: ${candidate.selected_update}\nEvaluation: ${labels[mode] || mode}\nCheckpoint: ${candidate.checkpoint_ref.uri}\nCheckpoint checksum: ${candidate.checkpoint_ref.checksum}\nPhysics evidence: ${evidence.data_ref.uri}\nPhysics checksum: ${evidence.data_ref.checksum}\nSource: MuJoCo physics simulation\nPhysical execution allowed: false`
      if (evidence.report.training) el('provenance').textContent += `\nActor origins: ${evidence.report.training.actor_origin_sampling}\nStudy SHA-256: ${evidence.report.training.source_study_sha256}\nPaired physical records: ${evidence.report.training.physical_records_new} new / ${evidence.report.training.physical_records_reused} reused`
      if (evidence.report.training?.model_replay_mode) el('provenance').textContent += `\nTraining cycles: ${evidence.report.training.cycles}\nDynamics replay: ${evidence.report.training.model_replay_mode}\nInitial windows retained: ${evidence.report.training.initial_anchor_windows} / ${evidence.report.training.model_replay_window_capacity} window capacity`
      el('inspector').hidden = false; el('empty-inspector').hidden = true; renderTrial()
      if (!embedded) selectToolTab(root, 'le-panel-inspect')
      el('status').textContent = `${trials.length} candidate trials loaded. ${trials.filter(trial => trial.failed).length} ended in falls.`
      if (embedded) el('status').textContent = `${trials.length} 条试验 · ${trials.filter(trial => trial.failed).length} 条因跌倒终止`
      el('selection').setAttribute('tabindex', '-1'); el('selection').focus()
    } catch (error) { if (token === generation) { clearInspection(); el('status').textContent = error.message } }
  }
  async function refresh() {
    const token = ++generation
    const selectedId = el('experiment').value
    clearInspection(); experiments = []; el('comparison').replaceChildren(); el('refresh').disabled = true; el('status').textContent = 'Loading registered experiments…'
    try {
      const resultPayload = await get('')
      const result = inspectLearningExperiments(resultPayload)
      if (token !== generation) return
      experiments = robotId ? result.filter(value => Object.hasOwn(resultPayload.experiment_robot_ids || {}, value.experiment_id) && resultPayload.experiment_robot_ids[value.experiment_id] === robotId) : result
      el('experiment').replaceChildren(...experiments.map(value => { const option = root.ownerDocument.createElement('option'); option.value = value.experiment_id; option.textContent = value.experiment_id; return option }))
      if (experiments.some(value => value.experiment_id === selectedId)) el('experiment').value = selectedId
      renderComparison()
      el('status').textContent = `${experiments.length} experiments · recorded simulation only`
      return { experiments, experiment_robot_ids: resultPayload.experiment_robot_ids || {}, replayIds: Array.isArray(resultPayload.replay_experiment_ids) ? resultPayload.replay_experiment_ids : [] }
    } catch (error) { if (token === generation) { el('comparison').textContent = 'Experiment list unavailable.'; el('status').textContent = error.message } }
    finally { el('refresh').disabled = false }
  }
  if (!embedded) root.ownerDocument.addEventListener('click', event => {
    const button = event.target.closest?.('[data-open-learning-experiments]')
    if (button) { opener = button; dialog.showModal(); selectToolTab(root, 'le-panel-compare'); pending = refresh() }
  })
  el('comparison').addEventListener('click', event => {
    const button = event.target.closest?.('[data-experiment]')
    if (button) pending = inspect(Number(button.dataset.experiment), Number(button.dataset.candidate))
  })
  el('refresh').addEventListener('click', () => { pending = refresh() })
  el('experiment').addEventListener('change', () => { ++generation; clearInspection(); renderComparison() })
  el('evaluation').addEventListener('change', () => { if (active) pending = inspect(active.ei, active.ci, el('evaluation').value) })
  el('trial').addEventListener('change', () => { cursor = 0; renderTrial() })
  el('first-passing').addEventListener('click', () => {
    if (!evidence) return
    const index = evidence.report.candidate.trials.findIndex(trial => learningTrialQuality(evidence.report, trial)?.passed)
    if (index >= 0) { el('trial').value = String(index); cursor = 0; renderTrial() }
  })
  el('cursor').addEventListener('input', () => { cursor = Number(el('cursor').value); renderTrial() })
  el('prev').addEventListener('click', () => { cursor = Math.max(0, cursor - 1); renderTrial() })
  el('next').addEventListener('click', () => { if (evidence) { cursor = Math.min(pairLearningTrial(evidence.report, Number(el('trial').value)).candidate.replay.length - 1, cursor + 1); renderTrial() } })
  el('end').addEventListener('click', () => { if (evidence) { cursor = pairLearningTrial(evidence.report, Number(el('trial').value)).candidate.replay.length - 1; renderTrial() } })
  el('close').addEventListener('click', () => dialog?.close())
  dialog?.addEventListener('close', () => { ++generation; el('refresh').disabled = false; opener?.focus() })
  if (embedded) el('panel-inspect').hidden = false
  return {
    refresh: () => { pending = refresh(); return pending },
    inspect: (ei, ci, mode) => { pending = inspect(ei, ci, mode); return pending },
    selectExperiment(id) { if (experiments.some(value => value.experiment_id === id)) { el('experiment').value = id; ++generation; clearInspection(); renderComparison(); if (embedded) el('status').textContent = '' } },
    whenIdle: () => pending,
  }
}
