export const TRANSFER_LAST = 6100;
export function elbowTransferPair(frame, leftStart, rightStart, leftTarget, rightTarget) {
  if (!Number.isInteger(frame) || frame < 0 || frame > TRANSFER_LAST) throw Error("无效肘部过渡帧");
  if (frame === 0 || frame === TRANSFER_LAST) return [leftStart, rightStart];
  if (frame >= 3000 && frame <= 3100) return [leftTarget, rightTarget];
  const u = frame < 3000 ? frame / 3000 : (frame - 3100) / 3000;
  const eased = u*u*u*(10+u*(-15+6*u));
  const weight = frame < 3000 ? eased : 1-eased;
  return [leftStart+(leftTarget-leftStart)*weight, rightStart+(rightTarget-rightStart)*weight];
}
export function elbowTransferPhase(frame) {
  return frame < 3000 ? "60 秒平滑进入双肘姿态" : frame <= 3100 ? "双肘保持 2 秒" : "60 秒平滑返回起始姿态";
}
