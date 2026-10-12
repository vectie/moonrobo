// Shared retained-evidence validation and comparison semantics. No I/O.
const DIGEST = /^sha256:[a-f0-9]{64}$/
const SLUG = /^[a-zA-Z0-9_-]{1,100}$/
export const METRICS = [
  ['distance_m', 'Distance', 'm'], ['duration_s', 'Duration', 's'],
  ['maximum_measured_segment_slope_deg', 'Maximum measured segment slope', 'deg'],
  ['waypoint_count', 'Waypoints', 'count'], ['delivery_count', 'Deliveries', 'count'],
  ['required_wh', 'Required energy', 'Wh'], ['available_wh', 'Available energy', 'Wh'],
  ['margin_wh', 'Energy margin', 'Wh'],
]

export function metric(evidence, key, unit) {
  const matches = Array.isArray(evidence?.metrics) ? evidence.metrics.filter((item) => item?.key === key) : []
  const item = matches.length === 1 ? matches[0] : null
  return item?.unit === unit && item.available === true && Number.isFinite(item.value) ? item.value : null
}

export function inspectRetainedTrial(payload, id) {
  const record = payload?.record, binding = record?.binding, evidence = binding?.frozen_evidence
  if (!SLUG.test(id) || record?.contract_id !== 'moonrobo.digital-trial.v1' ||
      record.import_request?.trial_id !== id || binding?.trial_id !== id ||
      !Number.isSafeInteger(record.revision) || record.revision < 0 || record.revision > 128 ||
      !Array.isArray(record.events) || record.events.length !== record.revision ||
      record.events.some((event) => !event || typeof event !== 'object' || !['lost-ack', 'review', 'reconcile'].includes(event.kind)) ||
      payload.physical_execution_allowed !== false || payload.automatic_retry_allowed !== false ||
      evidence?.contract_id !== 'moonrobo.frozen-digital-evidence.v1' || evidence.physical_execution_allowed !== false ||
      !['accepted', 'rejected'].includes(binding.digital_result) || !DIGEST.test(binding.result_digest)) {
    throw new Error('Retained trial identity or native evidence is invalid or unsupported. No evidence was changed.')
  }
  return { id, payload, record, binding, evidence,
    verifiedBaseline: evidence.baseline_verified === true && DIGEST.test(binding.baseline_digest) && evidence.baseline_digest === binding.baseline_digest,
  }
}

export function compareRetainedTrials(left, right) {
  const sameBaseline = !!(left?.verifiedBaseline && right?.verifiedBaseline && left.binding.baseline_digest === right.binding.baseline_digest)
  const complete = !!(left && right)
  return {
    state: !complete ? 'incomplete' : sameBaseline ? 'matching-verified-baseline' : 'different-or-unverified-baseline',
    message: !complete ? 'Choose and load both trials. No comparison is available.'
      : sameBaseline ? 'Matching verified baseline. Deltas are B minus A, descriptive only. No ranking or readiness conclusion.'
        : 'Different or unverified baseline. Side-by-side evidence only; numeric deltas are unavailable. No ranking or readiness conclusion.',
    rows: METRICS.map(([key, label, unit]) => {
      const a = metric(left?.evidence, key, unit), b = metric(right?.evidence, key, unit)
      const delta = sameBaseline && a !== null && b !== null && Number.isFinite(b - a) ? b - a : null
      return { key, label, unit, a, b, delta }
    }),
  }
}
