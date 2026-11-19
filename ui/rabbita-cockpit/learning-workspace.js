import { mountLearningExperiments } from './learning-experiments.js'
import { mountLearningReplay } from './learning-replay.js'
import { inspectResults, filterExperiments, motionGroup } from './results-data.js'
import { experimentsForRobot, RECORDED_ROBOT } from './robot-context.js'

const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const number = (value, digits = 3) => Number.isFinite(value) ? value.toFixed(digits) : '未记录'
const titles = {
  'reference-joint-initialization': '参考动作 · 关节初始化',
  'reference-feedforward-initialization': '参考动作 · 前馈初始化',
  'supermimic-aligned-smoke': 'SuperMimic · 对齐验证',
  'supermimic-smc-protocol-check': 'SuperMimic · SMC 协议验证',
}

// A persistent DOM island: Rabbita owns navigation; these controllers retain
// the selected trial, chart cursor, camera and playback time between tabs.
export function mountLearningWorkspace({ app, parking, hostUrl = '', fetchImpl = globalThis.fetch.bind(globalThis) }) {
  const document = app.ownerDocument
  const root = document.createElement('section')
  root.id = 'learning-workspace'
  root.innerHTML = `
    <div class="lw-context"><label for="lw-experiment">当前实验</label><select id="lw-experiment" disabled><option>正在读取本地实验…</option></select><button id="lw-refresh" class="icon-action" type="button" title="刷新实验" aria-label="刷新实验"><span class="robo-glyph glyph-refresh" aria-hidden="true"></span></button></div>
    <p id="lw-status" class="lw-status" role="status" aria-live="polite"></p>
    <section id="lw-experiments"><div class="lw-filters"><label><span class="visually-hidden">搜索实验</span><input id="lw-search" type="search" placeholder="搜索实验…"></label><label><span class="visually-hidden">记录类型</span><select id="lw-filter"><option value="">全部实验</option><option value="replay">含 3D 回放</option><option value="full">完整动作评测</option><option value="pass">含达标候选</option></select></label><span id="lw-count" role="status"></span></div><div id="lw-cards" class="lw-cards"></div></section>
    <section id="lw-results" hidden><div id="lw-candidates" class="lw-candidates"></div><div id="lw-full" hidden></div></section>
    <section id="lw-replay" hidden><div id="lw-replay-empty" class="lw-empty" hidden><span class="robo-glyph glyph-history" aria-hidden="true"></span><h3>暂无 3D 记录</h3><button id="lw-show-recordings" type="button" class="lw-primary">选择含回放的实验 <span aria-hidden="true">→</span></button></div><div id="lw-player"></div></section>`
  parking.append(root)
  const el = id => root.querySelector(`#lw-${id}`)
  const candidates = mountLearningExperiments({ root: el('candidates'), embedded: true, hostUrl, fetchImpl, robotId: RECORDED_ROBOT })
  const replay = mountLearningReplay({ root: el('player'), embedded: true, hostUrl, fetchImpl, robotId: RECORDED_ROBOT })
  const context = root.querySelector('.lw-context')
  let experiments = [], replayIds = [], selectedId = '', section = '', visible = false, loaded = false
  let pendingSection = ''
  let refreshing = false, resultsPackage, resultRequest, resultGeneration = 0, pending = Promise.resolve()
  const requested = new URLSearchParams(document.defaultView.location.search)
  let requestedId = requested.get('experiment') || ''
  let layoutFrame = 0, observedHeader, observedTabs
  const window = document.defaultView
  function fitFirstScreen() {
    if (layoutFrame) return
    layoutFrame = window.requestAnimationFrame(() => {
      layoutFrame = 0
      const header = document.querySelector('.cockpit-header')
      if (header) document.documentElement.style.setProperty('--cockpit-header-edge', `${Math.ceil(header.getBoundingClientRect().height + 16)}px`)
      if (!visible || section !== 'replay') return
      const stage = root.querySelector('.lr-stage'), dock = root.querySelector('.lr-dock')
      if (!stage?.getBoundingClientRect().height || !dock?.getBoundingClientRect().height) return
      // Size the picture from the remaining screen, reserving the complete
      // transport and timeline. Zoom and wrapped mobile controls are measured.
      const top = stage.getBoundingClientRect().top + window.scrollY
      const viewport = window.visualViewport?.height || window.innerHeight
      const height = Math.max(160, Math.floor(viewport - top - dock.getBoundingClientRect().height - 20))
      root.style.setProperty('--replay-stage-height', `${height}px`)
    })
  }
  const layoutObserver = new window.ResizeObserver(fitFirstScreen)
  layoutObserver.observe(root.querySelector('.lr-selectors'))
  layoutObserver.observe(root.querySelector('.lr-dock'))
  window.addEventListener('resize', fitFirstScreen)
  window.visualViewport?.addEventListener('resize', fitFirstScreen)
  function observeNavigation() {
    const header = document.querySelector('.cockpit-header'), tabs = document.querySelector('.cockpit-main > .workspace-tabs')
    if (header !== observedHeader) {
      if (observedHeader) layoutObserver.unobserve(observedHeader)
      if (header) layoutObserver.observe(header)
      observedHeader = header
    }
    if (tabs !== observedTabs) {
      if (observedTabs) layoutObserver.unobserve(observedTabs)
      if (tabs) layoutObserver.observe(tabs)
      observedTabs = tabs
    }
  }

  function navigate(next) {
    pendingSection = next
    document.querySelector('[data-workspace="data"]')?.click()
    const tab = document.getElementById(`section-${next}`)
    if (tab) { pendingSection = ''; tab.click() }
  }
  function updateUrl() {
    if (!visible || !selectedId) return
    const url = new URL(document.defaultView.location.href)
    url.searchParams.set('experiment', selectedId)
    url.searchParams.set('view', section)
    url.searchParams.set('robot', RECORDED_ROBOT)
    document.defaultView.history.replaceState(null, '', url)
  }
  function renderCards() {
    const rows = filterExperiments(experiments, el('search').value, el('filter').value, replayIds)
    el('count').textContent = `${rows.length} / ${experiments.length}`
    el('cards').innerHTML = rows.map(experiment => {
      const id = experiment.experiment_id, passing = experiment.candidates.filter(c => c.producer_qualified).length
      const recorded = replayIds.includes(id)
      return `<article class="lw-card${id === selectedId ? ' is-selected' : ''}"><button class="lw-open" type="button" data-lw-experiment="${escape(id)}" aria-label="查看 ${escape(id)} 的结果" ${id === selectedId ? 'aria-current="true"' : ''}><span class="robo-glyph glyph-${recorded ? 'history' : 'flask'}" aria-hidden="true"></span><span class="lw-name" title="${escape(id)}">${escape(titles[id] || id)}</span><span class="lw-recording">${recorded ? '3D' : ''}</span><span class="lw-outcome ${passing ? 'is-pass' : ''}">${experiment.candidates.length ? passing ? `${passing} 个记录达标` : '未达标' : '协议验证'}</span><span class="lw-arrow" aria-hidden="true">↗</span></button></article>`
    }).join('') || '<p class="lw-empty">没有匹配的实验。试试其他关键词。</p>'
  }
  async function loadResults() {
    if (!resultRequest) resultRequest = (async () => {
      const response = await fetchImpl('./results/smoke.json', { method: 'GET' })
      if (!response.ok) throw new Error('完整动作结果暂不可用，请刷新重试。')
      resultsPackage = inspectResults(await response.json())
      return resultsPackage
    })().catch(error => { resultRequest = null; throw error })
    return resultRequest
  }
  async function renderFullResult() {
    const token = ++resultGeneration, id = selectedId
    el('full').textContent = '正在读取已封存的动作结果…'
    try {
      const data = await loadResults()
      if (token !== resultGeneration || id !== selectedId) return
      const entry = data.evaluations.find(value => value.experiment_id === id)
      if (!entry) { el('full').innerHTML = '<p class="lw-empty">尚未导出这个实验的逐动作结果。</p>'; return }
      const evaluation = inspectResults({ ...data, evaluation: entry.evaluation }).evaluation
      el('full').innerHTML = `<div class="lw-metrics"><article><strong>${evaluation.n_failed}<small> / ${evaluation.n_clips}</small></strong><span>终止失败</span></article><article><strong>${number(evaluation.norm_return, 6)}</strong><span>平均归一化回报</span></article><article><strong>${evaluation.per_clip.filter(row => row.completed_full_duration).length}</strong><span>完整完成</span></article></div><div class="lw-filters"><label>搜索动作<input id="lw-motion-search" type="search" placeholder="动作名称"></label><label>动作类别<select id="lw-motion-group"><option value="">全部类别</option>${[...new Set(evaluation.per_clip.map(row => motionGroup(row.clip_id)))].map(group => `<option value="${escape(group)}">${escape(group)}</option>`).join('')}</select></label><span id="lw-motion-count" role="status"></span></div><div id="lw-motions" class="lw-motions"></div><details class="lw-source"><summary>数据来源</summary><p>封存结果 · ${escape(data.checked_at)} · 本次只读 smoke</p><a href="./results/${encodeURIComponent(entry.file)}" download>下载完整评测 JSON ↓</a></details>`
      const render = () => {
        const query = el('motion-search').value.toLowerCase().trim(), group = el('motion-group').value
        const rows = evaluation.per_clip.filter(row => row.clip_id.toLowerCase().includes(query) && (!group || motionGroup(row.clip_id) === group))
        el('motion-count').textContent = `${rows.length} / ${evaluation.n_clips} 条动作`
        el('motions').innerHTML = rows.map(row => {
          const rmse = row.strict_tracking?.rmse || {}
          return `<details class="lw-motion"><summary><strong>${escape(row.clip_id)}</strong><span>${number(row.executed_steps * .02, 2)} / ${number(row.expected_steps * .02, 2)} s</span><span class="${row.failed ? 'le-failed' : 'le-reported-pass'}">${row.failed ? '终止失败' : '未触发终止'}</span><span aria-hidden="true">＋</span></summary><dl><dt>归一化回报</dt><dd>${number(row.normalized_return, 6)}</dd><dt>关节误差</dt><dd>${number(rmse.joint_rmse_rad, 4)} rad</dd><dt>身体位置误差</dt><dd>${number(rmse.body_position_rmse_m, 4)} m</dd><dt>根部位置误差</dt><dd>${number(rmse.root_position_rmse_m, 4)} m</dd><dt>根部角度误差</dt><dd>${number(rmse.root_orientation_rmse_rad, 4)} rad</dd></dl></details>`
        }).join('') || '<p class="lw-empty">没有匹配的动作。</p>'
      }
      el('motion-search').addEventListener('input', render)
      el('motion-group').addEventListener('change', render)
      render()
    } catch (error) { if (token === resultGeneration) el('full').textContent = error.message }
  }
  function activateReplay() {
    const available = replayIds.includes(selectedId)
    const selectors = root.querySelector('.lr-selectors')
    const refreshParent = section === 'experiments' ? el('experiments').querySelector('.lw-filters') : context
    if (el('refresh').parentNode !== refreshParent) refreshParent.append(el('refresh'))
    if (section === 'replay' && available) {
      if (context.parentNode !== selectors) selectors.prepend(context)
    } else if (context.parentNode !== root) root.insertBefore(context, el('status'))
    el('replay-empty').hidden = available || refreshing
    el('player').hidden = !available
    replay.setActive(visible && section === 'replay' && available)
    if (visible && section === 'replay' && available) pending = replay.selectExperiment(selectedId)
    fitFirstScreen()
  }
  function selectExperiment(id) {
    const experiment = experiments.find(value => value.experiment_id === id)
    if (!experiment || id === selectedId) return
    selectedId = id; ++resultGeneration
    window.dispatchEvent(new window.CustomEvent('moonrobo:experiment-selected', { detail: { experimentId: id } }))
    el('experiment').value = id
    candidates.selectExperiment(id)
    replay.selectExperiment('')
    const full = experiment.candidates.length === 0
    el('candidates').hidden = full; el('full').hidden = !full
    if (full) pending = renderFullResult()
    renderCards(); activateReplay(); updateUrl()
  }
  async function refresh() {
    if (refreshing) return
    refreshing = true; el('refresh').disabled = true
    el('status').dataset.loading = 'true'; el('status').dataset.error = 'false'
    el('status').textContent = '正在连接本地实验…'
    const registry = await candidates.refresh()
    refreshing = false; el('refresh').disabled = false
    el('status').dataset.loading = 'false'
    if (!registry) {
      el('status').dataset.error = 'true'
      el('status').textContent = '实验服务暂不可用。已打开的回放可继续查看，点击刷新重试。'
      return
    }
    experiments = experimentsForRobot(registry, RECORDED_ROBOT).sort((a, b) => Number(registry.replayIds.includes(b.experiment_id)) - Number(registry.replayIds.includes(a.experiment_id)) || a.experiment_id.localeCompare(b.experiment_id))
    replayIds = registry.replayIds.filter(id => experiments.some(value => value.experiment_id === id))
    el('experiment').replaceChildren(...experiments.map(value => {
      const option = document.createElement('option'); option.value = value.experiment_id
      option.textContent = titles[value.experiment_id]?.replace('参考动作 · ', '').replace('SuperMimic · ', '') || value.experiment_id
      return option
    }))
    el('experiment').disabled = !experiments.length
    const previous = selectedId || requestedId
    const next = experiments.some(value => value.experiment_id === previous) ? previous : experiments[0]?.experiment_id
    selectedId = ''
    if (next) selectExperiment(next)
    else {
      ++resultGeneration; replay.selectExperiment('')
      el('candidates').hidden = true; el('full').hidden = false
      el('full').textContent = 'No experiments for this robot'
      activateReplay()
    }
    loaded = true; requestedId = ''
    el('status').textContent = `本地服务已连接 · ${experiments.length} 个实验 · ${replayIds.length} 个含 3D 回放`
    if (previous && previous !== next) el('status').textContent += ' · 原实验已不在当前目录'
    renderCards()
  }
  function sync() {
    observeNavigation()
    const slot = app.querySelector('[data-learning-section]')
    if (pendingSection) {
      const tab = document.getElementById(`section-${pendingSection}`)
      if (tab) {
        pendingSection = ''
        if (tab.getAttribute('aria-selected') !== 'true') { tab.click(); return }
      }
    }
    const wasVisible = visible
    visible = Boolean(slot)
    if (!slot) {
      if (root.parentNode !== parking) parking.append(root)
      if (wasVisible) replay.setActive(false)
      return
    }
    const changed = !wasVisible || slot.dataset.learningSection !== section
    if (root.parentNode !== slot) slot.append(root)
    const next = slot.dataset.learningSection
    if (next !== section) {
      section = next
      root.dataset.section = section
      for (const name of ['experiments', 'results', 'replay']) el(name).hidden = name !== section
      updateUrl()
    }
    if (!loaded && !refreshing) { loaded = true; pending = refresh() }
    if (changed) { window.scrollTo(0, 0); activateReplay() }
  }
  const observer = new document.defaultView.MutationObserver(sync)
  observer.observe(app, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-learning-section'] })
  root.addEventListener('click', event => {
    const selection = event.target.closest('[data-lw-experiment]')
    if (selection) { selectExperiment(selection.dataset.lwExperiment); navigate('results') }
    const next = event.target.closest('[data-lw-go]')
    if (next) navigate(next.dataset.lwGo)
  })
  el('experiment').addEventListener('change', () => selectExperiment(el('experiment').value))
  el('refresh').addEventListener('click', () => { pending = refresh() })
  el('search').addEventListener('input', renderCards)
  el('filter').addEventListener('change', renderCards)
  el('show-recordings').addEventListener('click', () => { el('filter').value = 'replay'; el('search').value = ''; renderCards(); navigate('experiments') })
  document.addEventListener('click', event => { if (event.target.closest?.('[data-open-learning-experiments]')) navigate('experiments') })
  if (requestedId) navigate(['results', 'replay'].includes(requested.get('view')) ? requested.get('view') : 'experiments')
  sync()
  return { whenIdle: () => pending, dispose() {
    observer.disconnect(); layoutObserver.disconnect()
    window.removeEventListener('resize', fitFirstScreen)
    window.visualViewport?.removeEventListener('resize', fitFirstScreen)
    if (layoutFrame) window.cancelAnimationFrame(layoutFrame)
    replay.dispose(); root.remove()
  } }
}
