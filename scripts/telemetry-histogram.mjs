// Shared explicit-bin observation statistics. Every finite observation has weight one.
export function validateEdges(edges) {
  if (!Array.isArray(edges) || edges.length < 2 || edges.length > 65 || edges.some((v, i) => typeof v !== 'number' || !Number.isFinite(v) || (i > 0 && v <= edges[i - 1]))) throw new Error('edges: supply 2 to 65 strictly increasing finite numbers');
}

// Internal helper: callers validate numeric observations and edges before using it.
export function histogram(values, edges) {
  const bins = edges.slice(0, -1).map((lower, i) => ({ lower, upper: edges[i + 1], upper_inclusive: i === edges.length - 2, count: 0 }));
  let underflow = 0, overflow = 0;
  for (const value of values) {
    if (value < edges[0]) underflow++;
    else if (value > edges.at(-1)) overflow++;
    else bins.find(bin => value >= bin.lower && (value < bin.upper || (bin.upper_inclusive && value === bin.upper))).count++;
  }
  const sorted = [...values].sort((a, b) => a - b);
  return {
    underflow, overflow,
    bins: bins.map(bin => ({ ...bin, fraction_of_selected_samples: values.length ? bin.count / values.length : null })),
    quantiles: [0, 25, 50, 75, 90, 95, 100].map(percentile => ({ percentile, value: sorted.length ? sorted[Math.max(0, Math.ceil(percentile / 100 * sorted.length) - 1)] : null })),
  };
}
