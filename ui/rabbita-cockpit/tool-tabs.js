// Static workspace definitions only; no user content is interpolated here.
export function toolTabs(prefix, sections) {
  return `<div class="workspace-tabs" role="tablist" aria-label="Tool sections">${sections.map(([key, label, icon], index) => `<button class="workspace-tab tool-tab${index === 0 ? ' active' : ''}" id="${prefix}-tab-${key}" type="button" role="tab" aria-controls="${prefix}-panel-${key}" aria-selected="${index === 0}" tabindex="${index === 0 ? 0 : -1}"><span class="robo-glyph glyph-${icon}" aria-hidden="true"></span><span>${label}</span></button>`).join('')}</div>`
}

export function selectToolTab(root, panelId) {
  const tabs = [...(root.querySelectorAll?.('.tool-tab') || [])]
  if (!tabs.some(tab => tab.getAttribute('aria-controls') === panelId)) return
  const focusedPanel = root.ownerDocument?.activeElement?.closest?.('[role="tabpanel"]')
  for (const tab of tabs) {
    const selected = tab.getAttribute('aria-controls') === panelId
    tab.setAttribute('aria-selected', String(selected))
    tab.tabIndex = selected ? 0 : -1
    tab.classList.toggle('active', selected)
    const panel = root.querySelector(`#${tab.getAttribute('aria-controls')}`)
    if (panel) panel.hidden = !selected
  }
  if (focusedPanel?.hidden) tabs.find(tab => tab.getAttribute('aria-controls') === panelId)?.focus()
}

export function installToolTabs(document) {
  document.addEventListener('click', event => {
    const tab = event.target.closest?.('.tool-tab')
    if (tab) selectToolTab(tab.closest('[data-tool-workspace]'), tab.getAttribute('aria-controls'))
  })
}
