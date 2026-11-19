// All quaternions are wxyz, in the same anatomical body basis. The reward
// compensates relative root yaw for each comparison, including mixed poses.
export const bodyNames = ["骨盆","左髋","左膝","左踝","右髋","右膝","右踝","躯干","左肩","左肘","左臂远端","右肩","右肘","右臂远端"];
export const frameWidth = 4*14*4;
export const radToDeg = 180/Math.PI;
export const controlHz = 50;

function product([w,x,y,z],[a,b,c,d]){
  return [w*a-x*b-y*c-z*d,w*b+x*a+y*d-z*c,w*c-x*d+y*a+z*b,w*d+x*c-y*b+z*a];
}
function yawCorrection(ref,actual){
  const [a,b,c,d]=ref;
  const [w,x,y,z]=product(actual,[a,-b,-c,-d]);
  let xx=1-2*(y*y+z*z), yx=2*(x*y+w*z);
  if(xx*xx+yx*yx<1e-12){xx=1-2*(x*x+z*z);yx=-2*(x*y-w*z);}
  const half=0.5*Math.atan2(yx,xx);
  return [Math.cos(half),0,0,Math.sin(half)];
}
function anglePair(ref,actual) {
  const [a,b,c,d]=ref;
  const [w,x,y,z]=product(actual,[a,-b,-c,-d]);
  return 2*Math.atan2(Math.hypot(x,y,z),Math.abs(w));
}
function errors(ref,actual) {
  const yaw=yawCorrection(ref[0],actual[0]);
  return ref.map((q,i)=>anglePair(product(yaw,q),actual[i]));
}
export function orientations(data, frame) {
  const offset=frame*frameWidth;
  return Array.from({length:4},(_,k)=>Array.from({length:14},(_,b)=>{
    const p=offset+(k*14+b)*4;
    const q=data.subarray(p,p+4), norm=Math.hypot(...q);
    if(!Number.isFinite(norm)||Math.abs(norm-1)>1e-5) throw Error("Invalid orientation quaternion");
    return Array.from(q,x=>x/norm);
  }));
}
export function frameErrors(data,frame) {
  const [s,r,a,g]=orientations(data,frame);
  return [errors(s,r),errors(r,a),errors(s,a),errors(s,g)];
}
export function bodyReward(angles) {
  return .02*Math.exp(-angles.reduce((s,x)=>s+x*x,0)/(14*.4**2));
}

// Exact additive allocation along the straight line in per-body squared
// errors between conditions. The exponential applies after averaging bodies.
export function gapShares(g,e,rg,re) {
  const delta=e.map((x,i)=>x*x-g[i]*g[i]);
  const sum=delta.reduce((x,y)=>x+y,0);
  const multiplier=Math.abs(sum)<1e-12?rg/(14*.4**2):(rg-re)/sum;
  return delta.map(v=>v*multiplier);
}
export function firstPersistent(series,limit,frames=5){
  let count=0;
  for(let i=0;i<series.length;i++){
    count=series[i]>limit?count+1:0;
    if(count===frames)return i-frames+1;
  }
  return null;
}
export function summarizePoseStream(data,clip,metrics) {
  const n=clip.steps, scale=clip.expected_steps*.1;
  if(data.length!==(n+1)*frameWidth || n<=0)throw Error("Unexpected frame count");
  const parts=bodyNames.map(()=>({squares:[0,0,0,0],gap:0}));
  const scores=[0,0,0,0]; let maxError=0;
  for(let f=0;f<=n;f++){
    const channels=frameErrors(data,f);
    if(f===0)continue;
    const reward=channels.map(bodyReward);
    for(const [k,col] of [[1,"e1"],[3,"g1"]]){
      const recorded=metrics[col][(f-1)*11+4];
      if(!Number.isFinite(recorded))throw Error("Missing measured orientation reward");
      maxError=Math.max(maxError,Math.abs(reward[k]-recorded));
    }
    const shares=gapShares(channels[3],channels[1],reward[3],reward[1]);
    for(let k=0;k<4;k++) {
      scores[k]+=reward[k]/scale;
      for(let b=0;b<14;b++)parts[b].squares[k]+=channels[k][b]**2/n;
    }
    for(let b=0;b<14;b++)parts[b].gap+=shares[b]/scale;
  }
  if(maxError>1e-7 || Math.abs(parts.reduce((v,p)=>v+p.gap,0)-(scores[3]-scores[1]))>1e-10)throw Error("Orientation reward reconciliation failed for "+clip.id);
  return {parts,scores,ceiling:n*.02/scale,maxError};
}
