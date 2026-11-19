export function inspectResults(data) {
  if (data?.format !== 'moonrobo.results-site-smoke.v1' || data.training_started !== false || data.physical_execution_allowed !== false || !Array.isArray(data.experiments)) throw new Error('结果包格式不匹配，请重新运行只读 smoke。')
  const evaluation = data.evaluation
  if (!Array.isArray(evaluation?.per_clip) || evaluation.n_clips !== evaluation.per_clip.length || evaluation.benchmark_complete !== true) throw new Error('动作评测不完整。')
  const ids = new Set()
  for (const row of evaluation.per_clip) {
    if (ids.has(row.clip_id) || !Number.isFinite(row.normalized_return) || !Number.isInteger(row.expected_steps) || row.expected_steps <= 0 || !Number.isInteger(row.executed_steps) || row.executed_steps < 0 || row.executed_steps > row.expected_steps || typeof row.failed !== 'boolean') throw new Error('逐动作记录无效。')
    ids.add(row.clip_id)
  }
  if (evaluation.n_failed !== evaluation.per_clip.filter(row => row.failed).length) throw new Error('失败计数与逐动作记录不一致。')
  return data
}

export const motionGroup = id => String(id).replace(/[0-9].*$/, '')

export function failureGroups(clips) {
  const groups = new Map()
  for (const clip of clips) {
    const name = motionGroup(clip.clip_id)
    const group = groups.get(name) || { name, count: 0, failed: 0 }
    group.count++; group.failed += Number(clip.failed)
    groups.set(name, group)
  }
  return [...groups.values()].sort((a, b) => b.count - a.count)
}

export function filterExperiments(experiments, query, mode, replayIds) {
  const search = query.toLowerCase().trim()
  return experiments.filter(e => e.experiment_id.toLowerCase().includes(search) &&
    (!mode || (mode === 'replay' && replayIds.includes(e.experiment_id)) ||
      (mode === 'pass' && e.candidates.some(c => c.producer_qualified === true)) ||
      (mode === 'full' && e.candidates.length === 0)))
}
