import {
  mv,
  tr,
  observation,
  goal,
  worldInput,
  integrate,
  flatten,
} from "./model.js";
const range = (n) => Array.from({ length: n }, (_, i) => i);
export function quaternion(r) {
  const parts = [
    1 + r[0] + r[4] + r[8],
    1 + r[0] - r[4] - r[8],
    1 - r[0] + r[4] - r[8],
    1 - r[0] - r[4] + r[8],
  ];
  const i = parts.indexOf(Math.max(...parts)),
    d = 2 * Math.sqrt(Math.max(parts[i], 1e-12));
  const q = [
    [d / 4, (r[7] - r[5]) / d, (r[2] - r[6]) / d, (r[3] - r[1]) / d],
    [(r[7] - r[5]) / d, d / 4, (r[1] + r[3]) / d, (r[2] + r[6]) / d],
    [(r[2] - r[6]) / d, (r[1] + r[3]) / d, d / 4, (r[5] + r[7]) / d],
    [(r[3] - r[1]) / d, (r[2] + r[6]) / d, (r[5] + r[7]) / d, d / 4],
  ][i];
  const n = Math.hypot(...q);
  return q.map((x) => x / n);
}
function rotation(q) {
  const [w, x, y, z] = q;
  return [
    1 - 2 * (y * y + z * z),
    2 * (x * y - z * w),
    2 * (x * z + y * w),
    2 * (x * y + z * w),
    1 - 2 * (x * x + z * z),
    2 * (y * z - x * w),
    2 * (x * z - y * w),
    2 * (y * z + x * w),
    1 - 2 * (x * x + y * y),
  ];
}
function pushHistory(prev, obs) {
  if (!prev.length) return Array.from({ length: 10 }, () => obs);
  return [...prev.slice(1), obs];
}
export class Simulation {
  constructor(mj, model, policy, world) {
    this.mj = mj;
    this.model = model;
    this.policy = policy;
    this.world = world;
    const c = policy.meta.contract;
    if (
      model.nq !== 36 ||
      model.nu !== 29 ||
      Math.abs(model.opt.timestep - 0.005) > 1e-10
    )
      throw Error("G1 physics contract mismatch");
    this.joints = c.joints.map((name) =>
      mj.mj_name2id(model, mj.mjtObj.mjOBJ_JOINT.value, name),
    );
    this.actuators = this.joints.map((j) =>
      range(model.nu).find((i) => model.actuator_trnid[2 * i] === j),
    );
    if (
      this.joints.some((i) => i < 1) ||
      new Set(this.joints).size !== 29 ||
      this.actuators.some((i) => i === undefined)
    )
      throw Error("G1 actuator mapping mismatch");
    this.pelvis = mj.mj_name2id(model, mj.mjtObj.mjOBJ_BODY.value, "pelvis");
    this.data = new mj.MjData(model);
    this.refData = new mj.MjData(model);
    this.wmData = new mj.MjData(model);
    this.power = true;
    this.noise = 0;
    this.friction = 1;
    this.prediction = true;
    this.stopOnFall = true;
  }
  dispose() {
    for (const d of [this.data, this.refData, this.wmData]) d.delete();
    this.model.delete();
  }
  setFriction(mu) {
    this.friction = mu;
    for (let i = 0; i < this.model.ngeom; i++)
      this.model.geom_friction[3 * i] = mu;
    for (let i = 0; i < this.model.npair; i++) {
      this.model.pair_friction[i * 5] = mu;
      this.model.pair_friction[i * 5 + 1] = mu;
    }
  }
  pose(data, s, clamp = false) {
    data.qpos.set(s.p, 0);
    data.qpos.set(quaternion(s.r), 3);
    data.qvel.set(s.v, 0);
    data.qvel.set(mv(tr(s.r), s.w), 3);
    this.joints.forEach((j, i) => {
      const pos = this.model.jnt_qposadr[j],
        dof = this.model.jnt_dofadr[j];
      data.qpos[pos] = clamp
        ? Math.min(
            this.model.jnt_range[2 * j + 1],
            Math.max(this.model.jnt_range[2 * j], s.q[i]),
          )
        : s.q[i];
      data.qvel[dof] = s.qd[i];
    });
    this.mj.mj_forward(this.model, data);
  }
  read() {
    const d = this.data,
      r = rotation(d.qpos.slice(3, 7));
    return {
      p: Array.from(d.qpos.slice(0, 3)),
      r,
      v: Array.from(d.qvel.slice(0, 3)),
      w: mv(r, d.qvel.slice(3, 6)),
      q: this.joints.map((j) => d.qpos[this.model.jnt_qposadr[j]]),
      qd: this.joints.map((j) => d.qvel[this.model.jnt_dofadr[j]]),
    };
  }
  reset(clip, frame = 0) {
    this.clip = clip;
    this.i = frame;
    this.end = "";
    this.impulse = null;
    this.history = [];
    this.prev = Array(29).fill(0);
    this.rng = 178;
    this.tick = 0;
    this.mj.mj_resetData(this.model, this.data);
    this.pose(this.data, clip[frame], true);
    this.setFriction(this.friction);
    this.pred = this.read();
    this.predPrev = this.prev.slice();
    this.predHistory = [];
    this.pose(this.wmData, this.pred);
    this.pose(this.refData, clip[frame]);
    this.drift = 0;
  }
  push(dx = 1, dy = 0) {
    this.impulse = { n: 5, x: dx * 100, y: dy * 100 };
  }
  step() {
    if (this.end) return;
    const at = this.i,
      ref = this.clip[at],
      state = this.read(),
      c = this.policy.meta.contract,
      g = goal(this.clip, at);
    this.history = pushHistory(
      this.history,
      observation(state, this.prev, ref, c.default_q),
    );
    let action = this.power
      ? this.policy.action(this.history, g)
      : Array(29).fill(0);
    const noise = action.map(() => {
      this.rng = (Math.imul(1664525, this.rng) + 1013904223) >>> 0;
      return (this.rng / 2147483648 - 1) * this.noise;
    });
    action = action.map((x, i) => x + noise[i]);
    if (this.prediction) {
      // Each horizon starts at the actual simulated state and policy history.
      // Subsequent actions use the predicted state and its own action history.
      if (this.tick % 32 === 0) {
        this.pred = state;
        this.predPrev = this.prev;
        this.predHistory = this.history.slice();
      } else
        this.predHistory = pushHistory(
          this.predHistory,
          observation(this.pred, this.predPrev, ref, c.default_q),
        );
      let a = this.power
        ? this.policy.action(this.predHistory, g)
        : Array(29).fill(0);
      a = a.map((x, i) => x + noise[i]);
      this.pred = integrate(
        this.pred,
        this.world.delta(worldInput(this.pred, a, this.friction)),
      );
      this.predPrev = a;
    }
    this.actuators.forEach((j, i) => {
      this.data.ctrl[j] = c.default_q[i] + c.action_scales[i] * action[i];
    });
    this.data.xfrc_applied.fill(0);
    if (this.impulse) {
      this.data.xfrc_applied[this.pelvis * 6] = this.impulse.x;
      this.data.xfrc_applied[this.pelvis * 6 + 1] = this.impulse.y;
      if (--this.impulse.n === 0) this.impulse = null;
    }
    for (let k = 0; k < 4; k++) this.mj.mj_step(this.model, this.data);
    this.mj.mj_forward(this.model, this.data);
    this.prev = action;
    this.i++;
    this.tick++;
    const next = this.clip[this.i],
      now = this.read();
    this.pose(this.refData, next);
    if (!flatten(now).every(Number.isFinite))
      throw Error("Nonfinite MuJoCo state");
    if (this.prediction) {
      if (!flatten(this.pred).every(Number.isFinite))
        throw Error("Nonfinite learned prediction");
      this.pose(this.wmData, this.pred);
      this.drift = Math.hypot(...this.pred.p.map((x, j) => x - now.p[j]));
    }
    if (
      this.stopOnFall &&
      (Math.abs(next.p[2] - now.p[2]) > 0.25 ||
        Math.abs(next.r[8] - now.r[8]) > 0.8)
    )
      this.end = "Reference-relative termination";
    else if (this.i >= this.clip.length - 1) this.end = "Motion complete";
  }
}
