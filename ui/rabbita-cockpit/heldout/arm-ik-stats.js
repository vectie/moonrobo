export const modes=["original","shoulders","elbows","both","arms-only","arms-guarded"];
export const labels=["原版","只加肩","只加肘","肩肘都加","肩肘都加 · 锁住下身","锁住下身 · 几何复查"];
export const reasons={stance_position:"支撑脚位置",stance_orientation:"支撑脚朝向",sole_penetration:"脚底穿透",task_body_rms:"身体位置 RMS",self_collision:"自碰撞",joint_speed:"关节速度",joint_range:"关节角限位"};

export function summarize(clips,feetScope){
  return modes.map((mode,i)=>{
    const rows=clips.map(c=>c.variants[i]);
    if(!rows.length || rows.some(v=>v.mode!==mode))throw Error("实验分组不匹配");
    const sum=fn=>rows.reduce((total,row)=>total+fn(row),0);
    const mean=fn=>sum(fn)/rows.length;
    const footSum=key=>sum(v=>v[feetScope][key]);
    const samples=footSum("samples"),slip=footSum("slip_samples");
    return {
      ret:mean(v=>v.normalized_return),done:sum(v=>Number(v.completed)),screen:sum(v=>Number(v.screen)),
      elbows:[0,1].map(k=>mean(v=>v.elbow_zero_deg[k])),over15:[0,1].map(k=>sum(v=>Number(v.elbow_zero_deg[k]>15))),persistent:[0,1].map(k=>sum(v=>Number(v.elbow_persistent[k]))),
      angles:[0,1,2].map(k=>Math.sqrt(mean(v=>v.right_shoulder_mse_rad2[k]))*180/Math.PI),
      feet:{samples,ratios:["touching","near","lifted"].map(k=>samples?100*footSum(k)/samples:null),
        peak:Math.max(...rows.map(v=>v[feetScope].peak_penetration_m))*1000,
        speed:slip?100*50*footSum("slip_distance_m")/slip:null,slip}
    };
  });
}
