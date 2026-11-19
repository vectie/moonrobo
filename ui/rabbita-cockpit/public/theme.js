// Run before paint. Theme changes never recreate a viewer or reset a recording.
(() => {
  const key = 'moonrobo.theme'
  let theme = 'dark'
  try { if (localStorage.getItem(key) === 'light') theme = 'light' } catch {}
  const root = document.documentElement
  function syncButtons() {
    const chinese = root.lang.startsWith('zh')
    const label = theme === 'dark'
      ? (chinese ? '切换浅色模式' : 'Switch to light mode')
      : (chinese ? '切换深色模式' : 'Switch to dark mode')
    for (const button of document.querySelectorAll('[data-theme-toggle]')) {
      if (button.title !== label) button.title = label
      if (button.getAttribute('aria-label') !== label) button.setAttribute('aria-label', label)
      button.setAttribute('aria-pressed', String(theme === 'light'))
    }
  }
  function apply() {
    root.dataset.theme = theme
    root.style.colorScheme = theme
    syncButtons()
    window.dispatchEvent(new CustomEvent('moonrobo:theme-change', { detail: { theme } }))
  }
  apply()
  document.addEventListener('click', event => {
    if (!event.target.closest?.('[data-theme-toggle]')) return
    theme = theme === 'dark' ? 'light' : 'dark'
    try { localStorage.setItem(key, theme) } catch {}
    apply()
  })
  new MutationObserver(syncButtons).observe(root, { childList: true, subtree: true })
  new MutationObserver(syncButtons).observe(root, { attributes: true, attributeFilter: ['lang'] })
  window.addEventListener('storage', event => {
    if (event.key !== key) return
    theme = event.newValue === 'light' ? 'light' : 'dark'
    apply()
  })
})()
