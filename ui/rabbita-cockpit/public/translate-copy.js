// Only catalogued interface copy is translated. Identifiers and user content
// are left alone; callers exclude content/technical scopes from DOM traversal.
export function createCopyTranslator(messages, templates = []) {
  const english = Object.create(null)
  const chinese = Object.assign(Object.create(null), messages)
  for (const [en, zh] of Object.entries(messages)) english[zh] ??= en
  const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const counts = new Set(['count', 'shown', 'total', 'pass', 'passing', 'failed', 'falls', 'replays', 'seed', 'done', 'percent', 'blockers', 'actions', 'links', 'joints', 'visuals', 'collisions', 'inertials', 'materials', 'extensions', 'parent', 'child', 'loaded', 'undo', 'redo'])
  function compile(source, target) {
    const names = []; let cursor = 0, pattern = '^'
    for (const match of source.matchAll(/\{([A-Za-z][A-Za-z0-9_]*)\}/g)) {
      pattern += escape(source.slice(cursor, match.index)) + (counts.has(match[1]) ? '([0-9,]+)' : '(.+?)')
      names.push(match[1]); cursor = match.index + match[0].length
    }
    return { regex: new RegExp(pattern + escape(source.slice(cursor)) + '$'), names, target }
  }
  const patterns = {
    'zh-Hans': templates.map(({ source, target }) => compile(source, target)),
    'en-US': templates.map(({ source, target }) => compile(target, source)),
  }
  return function translateCopy(text, locale) {
    const catalog = locale === 'zh-Hans' ? chinese : english
    const leading = text.match(/^\s*/)[0], trailing = text.match(/\s*$/)[0]
    const core = text.trim()
    let translated = catalog[core]
    if (translated === undefined) for (const pattern of patterns[locale] || []) {
      const match = core.match(pattern.regex)
      if (!match) continue
      const params = Object.fromEntries(pattern.names.map((name, i) => [name, catalog[match[i + 1]] ?? match[i + 1]]))
      translated = pattern.target.replace(/\{([A-Za-z][A-Za-z0-9_]*)\}/g, (_, name) => params[name])
      break
    }
    // Decorative arrows belong to the control, not to its translated label.
    if (translated === undefined) {
      const suffix = core.match(/^(.*?)\s*([↗↓×])$/)
      if (suffix) {
        const label = translateCopy(suffix[1], locale)
        if (label !== suffix[1]) translated = label + ' ' + suffix[2]
      }
    }
    if (translated === undefined && core.includes(' · ')) {
      translated = core.split(' · ').map(part => translateCopy(part, locale)).join(' · ')
    }
    return translated === undefined ? text : leading + translated + trailing
  }
}
