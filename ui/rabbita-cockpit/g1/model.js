// A browser consumer of the MoonBit export. The simulator and world model use
// 76 scalars: p, row-major R, world v/w, and the 29 joint positions/velocities.
const f = Math.fround;
const fl = new Float32Array(1),
  bits = new Uint32Array(fl.buffer);
export function bf16(x) {
  fl[0] = x;
  const u = bits[0];
  bits[0] = (u + 0x7fff + ((u >>> 16) & 1)) & 0xffff0000;
  return fl[0];
}
export const vec = (a, b, sgn = 1) => a.map((v, i) => v + sgn * b[i]);
export const mv = (r, x) =>
  [0, 3, 6].map((i) => r[i] * x[0] + r[i + 1] * x[1] + r[i + 2] * x[2]);
export const tr = (r) => [r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]];
export const mm = (a, b) =>
  [0, 3, 6].flatMap((i) =>
    [0, 1, 2].map(
      (j) => a[i] * b[j] + a[i + 1] * b[j + 3] + a[i + 2] * b[j + 6],
    ),
  );
const six = (r) => [r[0], r[1], r[3], r[4], r[6], r[7]];
function heading(r) {
  const left = r[4] ** 2 + r[1] ** 2 > r[0] ** 2 + r[3] ** 2,
    x = left ? r[4] : r[0],
    y = left ? -r[1] : r[3],
    n = Math.max(Math.hypot(x, y), 1e-12);
  return [x / n, -y / n, 0, y / n, x / n, 0, 0, 0, 1];
}
export function frame(row) {
  return {
    p: row.slice(0, 3),
    r: row.slice(3, 12),
    v: row.slice(12, 15),
    w: row.slice(15, 18),
    q: row.slice(18, 47),
    qd: row.slice(47, 76),
  };
}
export const flatten = (s) => [...s.p, ...s.r, ...s.v, ...s.w, ...s.q, ...s.qd];
export function observation(s, prev, ref, defaults) {
  return [
    ...vec(s.q, defaults, -1),
    ...s.qd,
    ...mv(tr(s.r), s.w),
    -s.r[6],
    -s.r[7],
    -s.r[8],
    ...prev,
    ...six(mm(tr(s.r), ref.r)),
  ];
}
export function goal(clip, i) {
  const now = clip[i],
    ht = tr(heading(now.r)),
    out = [];
  for (let k = 1; k <= 10; k++) {
    const s = clip[Math.min(i + k, clip.length - 1)],
      rt = tr(s.r);
    out.push(
      ...mv(ht, vec(s.p, now.p, -1)),
      ...six(mm(ht, s.r)),
      ...mv(rt, s.v),
      ...mv(rt, s.w),
      ...s.q,
      ...s.qd.map((v) => v * 0.1),
    );
  }
  return out;
}
export function worldInput(s, a, friction) {
  const rt = tr(s.r);
  return [
    s.p[2],
    ...six(mm(tr(heading(s.r)), s.r)),
    ...mv(rt, s.v),
    ...mv(rt, s.w),
    ...s.q,
    ...s.qd,
    ...a,
    (friction - 0.75) / 0.45,
    ...Array(32).fill(0),
  ];
}
export function integrate(s, d) {
  const [x, y, z] = d.slice(3, 6),
    t = Math.hypot(x, y, z),
    a = t < 1e-6 ? 1 - (t * t) / 6 : Math.sin(t) / t,
    b = t < 1e-6 ? 0.5 - (t * t) / 24 : (1 - Math.cos(t)) / (t * t),
    K = [0, -z, y, z, 0, -x, -y, x, 0],
    K2 = mm(K, K);
  const rot = K.map((v, i) => (i % 4 === 0 ? 1 : 0) + a * v + b * K2[i]);
  return {
    p: vec(s.p, mv(heading(s.r), d.slice(0, 3))),
    r: mm(s.r, rot),
    v: vec(s.v, mv(s.r, d.slice(6, 9))),
    w: vec(s.w, mv(s.r, d.slice(9, 12))),
    q: vec(s.q, d.slice(12, 41)),
    qd: vec(s.qd, d.slice(41)),
  };
}
export async function digest(buffer) {
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", buffer)),
    (v) => v.toString(16).padStart(2, "0"),
  ).join("");
}
export async function modelFromBytes(meta, buffer, kernel) {
  if (
    meta.format !== "moonrobo.browser-g1.v1" ||
    meta.contract.observation_dim !== 99 ||
    meta.contract.history_frames !== 10 ||
    meta.contract.joints.length !== 29 ||
    buffer.byteLength !== meta.floats * 4 ||
    (await digest(buffer)) !== meta.sha256
  )
    throw Error("Model or checkpoint digest mismatch");
  const space = 2048,
    mem = new WebAssembly.Memory({
      initial: Math.ceil((buffer.byteLength + space * 8) / 65536),
    }),
    heap = new Float32Array(mem.buffer);
  heap.set(new Float32Array(buffer));
  const {
    exports: { linear },
  } = await WebAssembly.instantiate(kernel, { model: { memory: mem } });
  for (const net of Object.values(meta.networks))
    for (const l of net) {
      const end = l.start + (l.input + 1) * l.output;
      if (
        !Number.isInteger(l.start) ||
        l.start < 0 ||
        l.input > space ||
        l.output > space ||
        l.output < 1 ||
        l.input < 1 ||
        end + (l.layerNorm ? 2 * l.output : 0) > meta.floats
      )
        throw Error("Invalid tensor layout");
      for (let i = l.start; i < end; i++) heap[i] = bf16(heap[i]);
    }
  function run(net, input) {
    let src = meta.floats,
      dst = src + space;
    if (input.length !== net[0].input) throw Error("Wrong network input width");
    for (let i = 0; i < input.length; i++) heap[src + i] = bf16(input[i]);
    for (let n = 0; n < net.length; n++) {
      const l = net[n],
        b = l.start + l.input * l.output;
      linear(4 * l.start, 4 * b, 4 * src, 4 * dst, l.input * 4, l.output);
      const out = heap.subarray(dst, dst + l.output);
      for (let j = 0; j < out.length; j++) out[j] = bf16(out[j]);
      if (l.layerNorm) {
        let sum = 0,
          varsum = 0;
        for (const v of out) sum += v;
        const mean = sum / out.length;
        for (const v of out) varsum += (v - mean) ** 2;
        const inv = 1 / Math.sqrt(varsum / out.length + 1e-5);
        for (let j = 0; j < out.length; j++) {
          const x = f(
            (out[j] - mean) * inv * heap[b + l.output + j] +
              heap[b + 2 * l.output + j],
          );
          out[j] = bf16(x / (1 + Math.exp(-x)));
        }
      } else if (n < net.length - 1) {
        for (let j = 0; j < out.length; j++) {
          const x = out[j];
          out[j] = bf16(x < 0 ? Math.expm1(x) : x);
        }
      }
      [src, dst] = [dst, src];
    }
    return Array.from(heap.subarray(src, src + net.at(-1).output));
  }
  const norms = meta.normalizers.map((n, i) => ({
    mean: n.mean,
    std: n.variance.map((v) => f(Math.sqrt(f(v + (i === 1 ? 1e-8 : 1e-4))))),
  }));
  const norm = (v, i) => {
    const n = norms[i];
    return v.map((x, j) => f(f(f(x) - n.mean[j]) / n.std[j]));
  };
  return {
    meta,
    action(history, g) {
      const z = run(meta.networks.encoder, norm(g, 3)).map((x) =>
        f(Math.tanh(x)),
      );
      return run(meta.networks.decoder, [
        ...z,
        ...history.flatMap((x) => norm(x, 2)),
      ]);
    },
    delta(input) {
      const n = norms[1];
      return run(meta.networks.world, norm(input, 0)).map((v, j) =>
        f(f(v * n.std[j]) + n.mean[j]),
      );
    },
  };
}
