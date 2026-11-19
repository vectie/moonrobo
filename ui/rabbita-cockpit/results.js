import './learning-replay.css'
import './results.css'
import { inspectResults, motionGroup, failureGroups, filterExperiments } from './results-data.js'
import { inspectLearningExperiments } from './learning-experiments.js'
import { mountLearningReplay } from './learning-replay.js'

const el = id => document.getElementById(id)
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const number = (value, digits = 3) => Number.isFinite(value) ? value.toFixed(digits) : '未记录'
const integer = value => Number.isFinite(value) ? value.toLocaleString('zh-CN') : '未记录'
let data, activeEvaluation, experiments = [], replayIds = [], replayController, focusedOpener

function activate(group, selected) {
  for (const tab of group.querySelectorAll('[role="tab"]')) {
    const active = tab === selected
    tab.setAttribute('aria-selected', String(active)); tab.tabIndex = active ? 0 : -1
    el(tab.getAttribute('aria-controls')).hidden = !active
  }
}

function navigate(hash = location.hash) {
  const name = hash.slice(1) || 'overview'
  const paper = name === 'paper'
  activate(document.querySelector('.source-tabs'), el(paper ? 'source-paper' : 'source-local'))
  if (paper) {
    if (!el('paper-frame').getAttribute('src')) el('paper-frame').src = el('paper-frame').dataset.src
  } else {
    el('paper-frame').removeAttribute('src')
    const section = ['motions', 'experiments', 'method'].includes(name) ? name : 'overview'
    activate(document.querySelector('.section-tabs'), el(`tab-${section}`))
  }
  const showingReplay = !paper && !el('overview').hidden
  el('replay-shell').open = showingReplay
  if (!showingReplay) replayController?.pause()
  if (name === 'replay') el('replay').scrollIntoView({ block: 'start' })
  else window.scrollTo(0, 0)
}

for (const group of document.querySelectorAll('[role="tablist"]')) {
  group.addEventListener('click', event => {
    const tab = event.target.closest('[role="tab"]')
    if (!tab) return
    location.hash = tab.id === 'source-paper' ? 'paper' : tab.id === 'source-local' ? 'overview' : tab.getAttribute('aria-controls')
  })
  group.addEventListener('keydown', event => {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return
    const tabs = [...group.querySelectorAll('[role="tab"]')]
    const index = tabs.indexOf(event.target)
    if (index < 0) return
    event.preventDefault()
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length
    tabs[next].focus(); tabs[next].click()
  })
}
window.addEventListener('hashchange', () => navigate())
navigate()

function showDialog(id, opener) {
  focusedOpener = opener
  el(id).showModal()
}
for (const dialog of [el('motion-detail'), el('experiment-detail')]) {
  dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close())
  dialog.addEventListener('close', () => focusedOpener?.focus())
}

function renderMotions() {
  const query = el('motion-search').value.toLowerCase().trim(), group = el('motion-group').value
  const rows = activeEvaluation.per_clip.filter(row => row.clip_id.toLowerCase().includes(query) && (!group || motionGroup(row.clip_id) === group))
  el('motion-count').textContent = `${rows.length} / ${activeEvaluation.n_clips} 条动作`
  el('motion-rows').innerHTML = rows.map(row => `<tr><td>${escape(row.clip_id)}</td><td>${number(row.normalized_return, 6)}</td><td>${number(row.executed_steps * .02, 2)} / ${number(row.expected_steps * .02, 2)} s</td><td><span class="${row.failed ? 'fail' : 'pass'}">${row.failed ? '终止失败' : '未触发终止'}</span></td><td><button data-motion="${escape(row.clip_id)}" aria-label="查看 ${escape(row.clip_id)} 的详情">详情 ↗</button></td></tr>`).join('') || '<tr><td colspan="5">没有匹配的动作。</td></tr>'
}

function renderEvaluation() {
  const entry = data.evaluations.find(value => value.experiment_id === el('motion-evaluation').value) || data.evaluations[0]
  activeEvaluation = entry.evaluation
  const evaluation = activeEvaluation
  el('evaluation-download').href = `./results/${entry.file}`
  el('motion-summary').innerHTML = `<div><strong>${evaluation.n_failed} / ${evaluation.n_clips}</strong><span>终止失败</span></div><div><strong>${number(evaluation.norm_return, 6)}</strong><span>平均归一化回报</span></div><div><strong>${evaluation.per_clip.filter(c => c.completed_full_duration).length}</strong><span>完整完成</span></div>`
  const groups = failureGroups(evaluation.per_clip)
  el('failure-chart').innerHTML = groups.map(group => `<div class="failure-row"><span>${escape(group.name)}</span><div class="failure-bar"><i style="width:${group.failed / Math.max(...groups.map(g => g.count)) * 100}%"></i></div><span>${group.failed}/${group.count}</span></div>`).join('')
  el('motion-group').innerHTML = '<option value="">全部类别</option>'
  for (const group of groups) { const option = document.createElement('option'); option.value = group.name; option.textContent = group.name; el('motion-group').append(option) }
  renderMotions()
}
el('motion-evaluation').addEventListener('change', renderEvaluation)
el('motion-search').addEventListener('input', renderMotions)
el('motion-group').addEventListener('change', renderMotions)
el('motion-rows').addEventListener('click', event => {
  const button = event.target.closest('[data-motion]')
  if (!button) return
  const row = activeEvaluation.per_clip.find(value => value.clip_id === button.dataset.motion)
  el('motion-title').textContent = row.clip_id
  const rmse = row.strict_tracking?.rmse || {}
  el('motion-detail-body').innerHTML = `<p class="muted">${row.failed ? '终止失败' : '未触发训练终止'} · ${row.protocol_complete ? '评测协议完整' : '评测未完成'}</p><dl><dt>归一化回报</dt><dd>${number(row.normalized_return, 6)}</dd><dt>执行时长</dt><dd>${number(row.executed_steps * .02, 2)} s</dd><dt>完整计划时长</dt><dd>${number(row.expected_steps * .02, 2)} s</dd><dt>关节误差</dt><dd>${number(rmse.joint_rmse_rad, 4)} rad</dd><dt>身体位置误差</dt><dd>${number(rmse.body_position_rmse_m, 4)} m</dd><dt>根部位置误差</dt><dd>${number(rmse.root_position_rmse_m, 4)} m</dd><dt>根部角度误差</dt><dd>${number(rmse.root_orientation_rmse_rad, 4)} rad</dd></dl><details><summary>完整记录</summary><pre>${escape(JSON.stringify(row, null, 2))}</pre></details>`
  showDialog('motion-detail', button)
})

function renderExperiments() {
  const filtered = filterExperiments(experiments, el('experiment-search').value, el('experiment-filter').value, replayIds)
  el('experiment-list').innerHTML = filtered.map(value => {
    const candidates = value.candidates, passing = candidates.filter(c => c.producer_qualified).length
    const hasReplay = replayIds.includes(value.experiment_id)
    return `<article class="experiment-card"><h2>${escape(value.experiment_id)}</h2><p>${candidates.length ? `${candidates.length} 个候选 · ${passing} 个记录达标` : '完整动作评测 · 独立协议'}${hasReplay ? ' · 含 3D 回放' : ''}</p><div class="card-bottom"><span class="record-badge">${candidates.length ? passing ? '含达标记录' : '未达标' : '方法验证'}</span><button data-experiment="${escape(value.experiment_id)}">查看结果 ↗</button></div></article>`
  }).join('') || '<p class="muted">没有匹配的实验。</p>'
}

async function refreshLibrary() {
  el('refresh-library').disabled = true
  try {
    const response = await fetch('./api/moondata/learning-experiments', { signal: AbortSignal.timeout(20000) })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    const result = await response.json()
    experiments = inspectLearningExperiments(result)
    replayIds = Array.isArray(result.replay_experiment_ids) ? result.replay_experiment_ids : []
    el('library-status').textContent = `本地服务已连接 · ${experiments.length} 个实验`
  } catch {
    experiments = data.experiments; replayIds = data.replay_experiment_ids
    el('library-status').textContent = `服务暂不可用 · 显示 ${data.checked_at} 导出的 ${experiments.length} 个实验`
  } finally { el('refresh-library').disabled = false; renderExperiments() }
}
el('refresh-library').addEventListener('click', refreshLibrary)
el('experiment-search').addEventListener('input', renderExperiments)
el('experiment-filter').addEventListener('change', renderExperiments)
el('experiment-list').addEventListener('click', event => {
  const button = event.target.closest('[data-experiment]')
  if (!button) return
  const experiment = experiments.find(value => value.experiment_id === button.dataset.experiment)
  const evaluationEntry = data.evaluations.find(value => value.experiment_id === experiment.experiment_id)
  el('experiment-title').textContent = experiment.experiment_id
  el('experiment-detail-body').innerHTML = `<p class="muted">仿真记录 · 不授予实机执行权限</p>${experiment.candidates.length ? `<div class="table-scroll"><table><thead><tr><th>种子</th><th>跌倒 / 试次</th><th>平均存活</th><th>结果</th></tr></thead><tbody>${experiment.candidates.map(candidate => `<tr><td>${candidate.seed}</td><td>${candidate.candidate.falls} / ${candidate.candidate.trials}</td><td>${number(candidate.candidate.mean_survival_s)} s</td><td>${candidate.producer_qualified ? '记录达标' : '未达标'}</td></tr>`).join('')}</tbody></table></div><div class="source-actions"><a class="pill primary" href="./?experiment=${encodeURIComponent(experiment.experiment_id)}">在工作台查看轨迹 ↗</a></div>` : `<p>该实验使用完整动作评测。</p>${evaluationEntry ? '<a class="pill" href="#motions" data-close-detail>查看逐动作结果 ↗</a>' : '<p class="muted">本次导出未包含此协议的逐动作结果。</p>'}`}<details><summary>来源记录</summary><pre>${escape(JSON.stringify(experiment, null, 2))}</pre></details>`
  el('experiment-detail-body').querySelector('[data-close-detail]')?.addEventListener('click', () => { el('motion-evaluation').value = experiment.experiment_id; renderEvaluation(); el('experiment-detail').close() })
  showDialog('experiment-detail', button)
})

async function init() {
  try {
    const response = await fetch('./results/smoke.json')
    if (!response.ok) throw new Error('请先运行结果页 smoke，生成本地结果包。')
    data = inspectResults(await response.json())
    const report = data.recorded_training, evaluation = data.evaluation
    el('page-status').textContent = '本地实验记录 · 只读验证'
    el('checked-at').textContent = new Date(data.checked_at).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false })
    el('highlights').innerHTML = [[data.experiments.length, '个', '已登记实验'], [evaluation.n_clips, '条', '完整协议 smoke 评测'], [data.checks.filter(c => c.status === 'passed').length, '项', '本轮只读检查通过']].map(([value, unit, label]) => `<article><strong>${integer(value)}</strong><span>${unit}</span><p>${label}</p></article>`).join('')
    el('compute-grid').innerHTML = [[number(report.wall_seconds_this_invocation, 2) + ' s', '历史短测墙钟时间'], [integer(report.counters.physical_transitions), '仿真转移'], [integer(report.counters.imagined_transitions), '想象转移'], [integer(report.iteration), '历史 smoke 迭代']].map(([value, label]) => `<article><strong>${value}</strong><p>${label}</p></article>`).join('')
    const coverage = [['完整动作评测', '已记录', `${evaluation.n_failed} / ${evaluation.n_clips} 终止失败，保留逐动作误差。`], ['计算量与成本', '部分记录', 'CPU smoke 计数可查；没有论文规模收敛曲线。'], ['交互式动作回放', '已记录', '两组初始化实验的参考动作与物理姿态。'], ['世界模型预测', '未登记', '没有同步预测姿态；不以参考动作替代。'], ['数据规模与梯度效率', '未运行', '未运行数据扩展、吞吐或 PPO-WM 对照。'], ['实机与零样本迁移', '未运行', '没有启动实机动作，也不提供实机成功声明。']]
    el('coverage-grid').innerHTML = coverage.map(([name, status, text]) => `<article><h3>${name}</h3><span>${status}</span><p>${text}</p></article>`).join('')
    for (const entry of data.evaluations) { const option = document.createElement('option'); option.value = entry.experiment_id; option.textContent = entry.experiment_id; el('motion-evaluation').append(option) }
    const requestedEvaluation = new URLSearchParams(location.search).get('evaluation')
    if (data.evaluations.some(entry => entry.experiment_id === requestedEvaluation)) el('motion-evaluation').value = requestedEvaluation
    renderEvaluation()
    const checkNames = { 'Local service': '本地服务响应', 'Read-only cockpit': '工作台只读模式', 'Experiment registry': '完整实验目录', 'Sealed smoke evaluation': '封存评测与 SHA-256 校验' }
    el('smoke-checks').innerHTML = data.checks.map(check => `<li>${escape(checkNames[check.name] || check.name.replace('3D replay:', '3D 回放：'))}${check.count ? ` · ${check.count}` : ''}</li>`).join('')
    el('provenance').textContent = JSON.stringify({ checked_at: data.checked_at, mode: data.mode, training_started: data.training_started, sources: data.sources, scope: data.scope }, null, 2)
    experiments = data.experiments; replayIds = data.replay_experiment_ids; renderExperiments()
    el('library-status').textContent = `${experiments.length} 个实验 · 导出快照`
    replayController = mountLearningReplay({ root: el('results-replay'), dialog: el('replay-shell') })
    el('results-replay').querySelector('details').open = true
    await refreshLibrary()
  } catch (error) {
    el('page-status').textContent = error.message
    document.querySelector('.hero-note').textContent = '结果包暂不可用'
  }
}
init()
