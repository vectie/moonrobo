// Shared offline numeric recording parser; timestamps remain exact Int64 strings.
const MAX_TIME = 9223372036854775807n;
const decimal = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
export function numeric(text, label) {
  if (!decimal.test(text) || !Number.isFinite(Number(text))) throw new Error(`${label}: expected finite decimal number`);
  return Number(text);
}
export function time(text, label) {
  if (!/^\d+$/.test(text) || BigInt(text) > MAX_TIME) throw new Error(`${label}: expected nonnegative Int64 milliseconds`);
  return BigInt(text);
}
export function label(text, name) {
  if (typeof text !== 'string' || !text.trim() || /[\x00-\x1f\x7f]/.test(text)) throw new Error(`${name}: expected nonblank printable label`);
  return text;
}

export function parseRecording(text) {
  const lines = text.split('\n');
  let channels, previous = -1n;
  const rows = [];
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].trim();
    if (!line) continue;
    const where = `line ${index + 1}`;
    if (line.includes('"')) throw new Error(`${where}: quoted CSV is unsupported`);
    const fields = line.split(',').map(value => value.trim());
    if (!channels) {
      if (fields[0] !== 'timestamp_ms' || fields.length < 2) throw new Error(`${where}: expected timestamp_ms and channels`);
      channels = fields.slice(1);
      channels.forEach(value => label(value, where));
      if (channels.includes('timestamp_ms') || new Set(channels).size !== channels.length) throw new Error(`${where}: duplicate or reserved channel`);
      continue;
    }
    if (fields.length !== channels.length + 1) throw new Error(`${where}: wrong column count`);
    const timestamp = time(fields[0], where);
    if (timestamp <= previous) throw new Error(`${where}: timestamps must strictly increase`);
    previous = timestamp;
    rows.push({ sample_index: rows.length, source_line: index + 1, timestamp_ms: timestamp.toString(), values: fields.slice(1).map(value => numeric(value, where)) });
  }
  if (!rows.length) throw new Error('recording must contain at least one sample');
  return { channels, rows };
}
