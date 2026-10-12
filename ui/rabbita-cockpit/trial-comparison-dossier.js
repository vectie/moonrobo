// Portable inspection only: no native reads, imports, reviews or execution.
import { inspectRetainedTrial, compareRetainedTrials } from './retained-trial-evidence.js'

export const DOSSIER_CONTRACT = 'moonrobo.trial-comparison-dossier.v1'
export const DOSSIER_LIMIT = 16 * 1024 * 1024
const DIGEST = /^sha256:[a-f0-9]{64}$/
const boundary = 'Historical digital evidence only. No atomic cross-trial snapshot, current-file promise, physical authority, retry, simulation, review, provider action or Book acceptance. SHA-256 checks integrity, not authorship or trust.'
const encoded = (text) => new TextEncoder().encode(text)
const safe = (value) => String(value ?? 'unavailable').replace(/[&<>"'`\\\[\]*_{}()#!|~]/g, (ch) => `&#${ch.codePointAt(0)};`).replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, (ch) => `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`)
const describe = (value) => safe(typeof value === 'string' ? value : JSON.stringify(value ?? null))

export async function dossierDigest(text) {
  const digest = await globalThis.crypto.subtle.digest('SHA-256', encoded(text))
  return 'sha256:' + [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

function observation(value, side) {
  if (!value || value.side !== side || typeof value.payload_json !== 'string' ||
      !Number.isSafeInteger(value.observed_at_ms) || value.observed_at_ms < 0 ||
      typeof value.host !== 'string' || value.host.length > 4096 || !DIGEST.test(value.payload_digest)) {
    throw new Error('Invalid portable observation identity or digest.')
  }
  const payload = JSON.parse(value.payload_json)
  const view = inspectRetainedTrial(payload, value.trial_id)
  if (typeof view.record.import_request.dossier_text !== 'string' || typeof view.record.import_request.result_text !== 'string') {
    throw new Error('Complete original dossier and result strings are required.')
  }
  return view
}

function report(envelope, views) {
  const comparison = compareRetainedTrials(...views)
  const lines = ['# Retained digital trial comparison', '', boundary, '',
    `Dossier ID: ${envelope.export_id}`, '',
    `Exported at client time: ${safe(envelope.exported_at_ms)} ms since Unix epoch.`,
    'Observation times are client receipt times, not authenticated host timestamps.', '',
    '## Comparison', '', comparison.message, '',
    ...comparison.rows.map((row) => `- ${row.label} (${row.unit}): A ${row.a ?? 'unavailable'}; B ${row.b ?? 'unavailable'}; B minus A ${row.delta ?? 'unavailable'}`),
  ]
  for (let index = 0; index < views.length; index++) {
    const view = views[index], item = envelope.observations[index]
    const { binding: b, evidence: e, record: r, payload: p } = view
    lines.push('', `## Trial ${item.side}: ${safe(view.id)}`, '',
      `Observed at client time: ${item.observed_at_ms}; host: ${safe(item.host)}.`,
      `Complete payload SHA-256: ${item.payload_digest}`, '',
      '### Frozen outcome and identity', '',
      `Digital result: ${safe(b.digital_result)}; retained revision: ${r.revision}.`,
      `Session: ${safe(b.session_id)}; attempt: ${safe(b.attempt_id)}; proof: ${safe(b.proof_id)}.`,
      `Robot: ${safe(b.robot_id)} / ${safe(b.robot_revision)}.`,
      `Baseline: ${safe(b.baseline_digest)}; host-recorded verification: ${view.verifiedBaseline} (an unauthenticated portable claim when reopened).`,
      `Dossier: ${safe(b.dossier_digest)}; result: ${safe(b.result_digest)}.`,
      `Scenario: ${safe(e.scenario_id)} / ${safe(e.scenario_kind)}; outcome: ${safe(e.scenario_outcome)}.`,
      `Final state: ${safe(e.final_state)}; claim: ${safe(e.evidence_claim)}; whole-grid status: ${safe(e.whole_grid_status)}.`,
      `Frozen blockers: ${describe(b.blockers)}.`, `Frozen limitations: ${describe(b.limitations)}.`, '',
      '### Historical host observation, not current state on this computer', '',
      `Binding: ${safe(p.binding_state)}; acknowledgement: ${safe(p.acknowledgement_state)}; retention: ${safe(p.retention_state)}.`,
      `Current-at-observation blockers: ${describe(p.current_binding_blockers)}.`,
      `Current-at-observation unknowns: ${describe(p.current_binding_unknowns)}.`,
      `Other blockers: ${describe(p.blockers)}; unknowns: ${describe(p.unknowns)}.`, '',
      '### Ordered inert event history', '',
      ...r.events.map((event, i) => `${i + 1}. ${describe(event)}`),
      ...(r.events.length ? [] : ['No events recorded.']), '',
      '### Frozen provenance', '',
      `Design: ${safe(e.design_ref)}; result: ${safe(e.result_ref)}.`,
      `Provenance: ${safe(e.provenance_ref)}; replay: ${safe(e.replay_ref)}.`,
      `Replays: ${safe(e.replay_completed)} / ${safe(e.replay_required)}; byte equivalence: ${e.replay_byte_equivalent === true ? 'verified frozen receipt' : 'unavailable'}.`,
      `Source digests: ${describe(e.provenance_source_digests)}.`,
      'The companion JSON retains the complete native payload, original dossier/result strings, all binding fields, metrics and ordered event records unchanged.',
    )
  }
  return lines.join('\n') + '\n'
}

async function exportIdentity(envelope) {
  return dossierDigest(JSON.stringify([DOSSIER_CONTRACT, envelope.exported_at_ms,
    envelope.observations.map((item) => [item.side, item.trial_id, item.observed_at_ms, item.host, item.payload_digest])]))
}

export async function createTrialComparisonDossier(left, right, exportedAt) {
  if (!left || !right || !Number.isSafeInteger(exportedAt) || exportedAt < 0) throw new Error('Load both trials before exporting.')
  const observations = []
  for (const [index, source] of [left, right].entries()) {
    // Capture every exact string now, before the first digest yields control.
    observations.push({ side: index === 0 ? 'A' : 'B', trial_id: source.id,
      observed_at_ms: source.observedAt, host: source.host,
      payload_json: source.payloadText ?? JSON.stringify(source.payload) })
  }
  if (observations.some((item) => encoded(item.payload_json).length > DOSSIER_LIMIT / 2)) throw new Error('Selected evidence exceeds the portable dossier size limit.')
  for (const item of observations) item.payload_digest = await dossierDigest(item.payload_json)
  const views = observations.map((item, index) => observation(item, index === 0 ? 'A' : 'B'))
  const envelope = { contract_id: DOSSIER_CONTRACT, exported_at_ms: exportedAt,
    physical_execution_allowed: false, automatic_retry_allowed: false,
    historical_observations_only: true, atomic_snapshot: false,
    observations, comparison: compareRetainedTrials(...views) }
  envelope.export_id = await exportIdentity(envelope)
  envelope.readable_markdown = report(envelope, views)
  envelope.manifest = { algorithm: 'SHA-256', encoding: 'UTF-8',
    payloads: observations.map((item) => ({ side: item.side, sha256: item.payload_digest })),
    readable_markdown_sha256: await dossierDigest(envelope.readable_markdown) }
  const json = JSON.stringify(envelope, null, 2) + '\n'
  if (encoded(json).length > DOSSIER_LIMIT) throw new Error('Portable dossier exceeds its size limit.')
  return { envelope, json, markdown: envelope.readable_markdown }
}

export async function verifyTrialComparisonDossier(text, companionMarkdown) {
  if (typeof text !== 'string' || encoded(text).length > DOSSIER_LIMIT) throw new Error('Portable dossier is missing or exceeds its size limit.')
  const e = JSON.parse(text)
  if (e?.contract_id !== DOSSIER_CONTRACT || e.physical_execution_allowed !== false ||
      e.automatic_retry_allowed !== false || e.historical_observations_only !== true || e.atomic_snapshot !== false ||
      !Number.isSafeInteger(e.exported_at_ms) || e.exported_at_ms < 0 ||
      !Array.isArray(e.observations) || e.observations.length !== 2 ||
      e.manifest?.algorithm !== 'SHA-256' || e.manifest.encoding !== 'UTF-8') throw new Error('Unsupported or invalid portable dossier.')
  const views = e.observations.map((item, index) => observation(item, index === 0 ? 'A' : 'B'))
  for (const item of e.observations) {
    if (await dossierDigest(item.payload_json) !== item.payload_digest) throw new Error('Payload digest mismatch.')
  }
  if (e.export_id !== await exportIdentity(e)) throw new Error('Dossier identity mismatch.')
  const expectedManifest = { algorithm: 'SHA-256', encoding: 'UTF-8',
    payloads: e.observations.map((item) => ({ side: item.side, sha256: item.payload_digest })),
    readable_markdown_sha256: await dossierDigest(report(e, views)) }
  if (e.readable_markdown !== report(e, views) || JSON.stringify(e.manifest) !== JSON.stringify(expectedManifest) ||
      JSON.stringify(e.comparison) !== JSON.stringify(compareRetainedTrials(...views))) throw new Error('Report, comparison or manifest digest mismatch.')
  if (companionMarkdown !== undefined && (typeof companionMarkdown !== 'string' || companionMarkdown !== e.readable_markdown || await dossierDigest(companionMarkdown) !== e.manifest.readable_markdown_sha256)) throw new Error('Companion Markdown does not match this JSON dossier.')
  return { envelope: e, markdown: e.readable_markdown,
    message: `Portable dossier integrity verified${companionMarkdown === undefined ? ' internally; companion Markdown not checked' : ' with matching companion Markdown'}. Self-consistency only, not authenticated native-store verification. Historical, untrusted evidence only; no live host was read and no native trial was imported.` }
}

export function downloadComparisonDossier(files, document = globalThis.document, url = globalThis.URL) {
  const stem = `trial-comparison-${files.envelope.export_id.slice(7, 23)}`
  for (const [name, content, type] of [[`${stem}.md`, files.markdown, 'text/markdown;charset=utf-8'], [`${stem}.json`, files.json, 'application/json']]) {
    const href = url.createObjectURL(new Blob([content], { type }))
    const link = document.createElement('a')
    link.href = href; link.download = name; document.body.appendChild(link)
    try { link.click() } finally { link.remove(); url.revokeObjectURL(href) }
  }
}
