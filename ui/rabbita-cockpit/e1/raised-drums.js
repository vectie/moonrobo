// Nominal preview of the raised-elbow reference, in absolute degrees.
// Live robot poses are supplied separately by the telemetry endpoint.
export const RAISED_LAST = 8550;
export function raisedPair(frame, leftStart, rightStart) {
  const f = Math.max(0, Math.min(RAISED_LAST, frame));
  if (f === RAISED_LAST) return [leftStart, rightStart];
  if (f <= 3000) {
    const blend = (1 - Math.cos(Math.PI * f / 3000)) / 2;
    return [leftStart + (-90 - leftStart) * blend, rightStart + (-90 - rightStart) * blend];
  }
  if (f < 3100) return [-90, -90];
  if (f < 6300) {
    const stroke = Math.floor((f - 3100) / 800);
    const drop = 15 * (1 - Math.cos(2 * Math.PI * ((f - 3100) % 800) / 800));
    return stroke % 2 === 0 ? [-90 + drop, -90] : [-90, -90 + drop];
  }
  const blend = (1 - Math.cos(Math.PI * (f - 6300) / 2250)) / 2;
  return [-90 + (leftStart + 90) * blend, -90 + (rightStart + 90) * blend];
}
export function raisedPhase(frame) {
  if (frame < 3000) return "双肘抬至 90°";
  if (frame < 3100) return "双肘保持 90°";
  if (frame < 6300) {
    const stroke = Math.floor((frame - 3100) / 800);
    const side = stroke % 2 === 0 ? "左肘" : "右肘";
    return `${side}${(frame - 3100) % 800 < 400 ? "下落至 60°" : "抬回 90°"} · 第 ${stroke + 1}/4 次`;
  }
  return frame < RAISED_LAST ? "双肘缓慢回到起始姿态" : "预览结束";
}
