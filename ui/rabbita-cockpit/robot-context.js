export const RECORDED_ROBOT = 'g1-simulation'
const contexts = new Set(['workspace', RECORDED_ROBOT])

export function resolveRobotContext({ search = '', stored = '', experimentRobotIds = {} } = {}) {
  const query = new URLSearchParams(search)
  const explicit = query.get('robot')
  if (contexts.has(explicit)) return explicit
  // A shared experiment link takes precedence over a remembered workspace.
  const owner = experimentRobotIds[query.get('experiment')]
  if (owner === RECORDED_ROBOT) return owner
  return contexts.has(stored) ? stored : 'workspace'
}

export function experimentsForRobot(registry, robotId) {
  return (registry.experiments || []).filter(experiment =>
    Object.hasOwn(registry.experiment_robot_ids || {}, experiment.experiment_id) &&
    registry.experiment_robot_ids[experiment.experiment_id] === robotId)
}

export function assertRobotReplay(replay, robotId) {
  if (robotId !== RECORDED_ROBOT || !/(?:^|:)unitree_g1\/[^:]+\.xml$/.test(replay.source?.model_ref || '')) {
    throw new Error('This recording belongs to a different robot.')
  }
  return replay
}

export async function installRobotContext({ hostUrl = '', window = globalThis, fetchImpl = globalThis.fetch.bind(globalThis) } = {}) {
  let stored = '', registry = { experiments: [], experiment_robot_ids: {}, replay_experiment_ids: [] }
  try { stored = window.localStorage.getItem('moonrobo.robot') || '' } catch { /* storage may be restricted */ }
  try {
    const response = await fetchImpl(`${hostUrl.replace(/\/$/, '')}/api/moondata/learning-experiments`, { signal: AbortSignal.timeout(6000) })
    if (response.ok) registry = await response.json()
  } catch { /* the workspace remains usable when recordings are offline */ }
  window.__MOONROBO_ROBOT_CONTEXT = resolveRobotContext({ search: window.location.search, stored, experimentRobotIds: registry.experiment_robot_ids })
  window.__moonroboRememberRobot = value => {
    if (!contexts.has(value)) return
    window.__MOONROBO_ROBOT_CONTEXT = value
    try { window.localStorage.setItem('moonrobo.robot', value) } catch { /* optional persistence */ }
    const url = new URL(window.location.href)
    url.searchParams.set('robot', value)
    window.history.replaceState(null, '', url)
  }
  return registry
}
