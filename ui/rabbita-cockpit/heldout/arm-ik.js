import {labels,modes,reasons,summarize} from "./arm-ik-stats.js";
const $=id=>document.getElementById(id);
const show=(x,n)=>x==null?"—":x.toFixed(n);
const signed=x=>(x<0?"−":"+")+show(Math.abs(x),4);
const short=id=>id.split("/").at(-1);
const node=(tag,txt,parent)=>{const e=document.createElement(tag);if(txt!=null)e.textContent=txt;parent?.append(e);return e;};
function row(id,values){const tr=node("tr",null,$(id));values.forEach((v,i)=>{const td=node(i?"td":"th",v,tr);if(!i)td.scope="row";});return tr;}
const replay=new URL($("replay").href);
let report,lockedScreens,guardedRefs;
function renderPair(clip){
  const picker=$("pair-frame"),section=$("pair-view");
  section.hidden=!clip;
  if(!clip)return;
  const traces=clip.pair_contact_traces, exemplar=traces[0];
  const limit=guardedRefs.get(clip.id).screen.rules.self_penetration_m;
  $("pair-attempts").replaceChildren();
  for(const a of guardedRefs.get(clip.id).arm_repair.attempts){
    row("pair-attempts",[show(a.fraction*100,2)+"%",show(a.peak_m*1000,2)+" mm",show(a.pair_excess_m*1000,2)+" mm"]);
  }
  const above=t=>t.reference_m.filter(depth=>depth>limit).length;
  $("pair-label").textContent=short(clip.id)+" · "+exemplar.bodies.join(" / ")+"。这对碰撞体的参考穿透超过 "+show(limit*1000,0)+" mm 的帧数从 "+above(traces[1])+" 降至 "+above(traces[2])+"。滑块起始位置是修复前的峰值帧。0 mm 表示该帧未检测到这对碰撞体穿透。";
  picker.max=exemplar.reference_m.length-1;
  if(picker.dataset.clip!==clip.id){
    picker.value=exemplar.peak_frame_before_repair;
    picker.dataset.clip=clip.id;
  }
  const draw=()=>{
    const frame=Number(picker.value);
    const url=new URL(replay);
    url.searchParams.set("motion",short(clip.id));url.searchParams.set("step",String(frame));url.searchParams.set("e1","arms-guarded");
    $("pair-replay").href=url;
    $("pair-frame-label").textContent=frame+" / "+picker.max;
    $("pair-rows").replaceChildren();
    for(const v of traces){
      const mm=(value)=>value==null?"已停止":show(value*1000,2)+" mm";
      row("pair-rows",[labels[modes.indexOf(v.mode)],mm(v.reference_m[frame]),mm(v.recorded_pose_m[frame])]);
    }
  };
  picker.oninput=draw;draw();
}
function render(){
  const index=$("scope").selectedIndex-1;
  const clips=index<0?report.clips:[report.clips[index]];
  const n=clips.length, sum=summarize(clips,$("feet-scope").value);
  const common=clips.reduce((s,c)=>s+c.shared_steps,0);
  for(const id of ["outcomes","elbows","contacts","angle-chart","motion-list"])$(id).replaceChildren();
  const motion=index<0?"M_Move3":short(clips[0].id);
  const link=new URL(location.href);if(index<0)link.searchParams.delete("motion");else link.searchParams.set("motion",motion);
  history.replaceState(null,"",link);
  const orientation=new URL("./orientation.html",location.href);orientation.searchParams.set("motion",motion);$("orientation").href=orientation;
  const back=new URL(replay);back.searchParams.set("motion",motion);$("replay").href=back;
  back.searchParams.set("e1","arms-guarded");$("guard-replay").href=back;
  const unit=x=>show(x,1)+"°";
  const angleMax=Math.max(1,...sum.flatMap(v=>v.angles));
  const count=x=>x+"/"+n;
  sum.forEach((r,i)=>{
    row("outcomes",[labels[i],...r.elbows.map(unit),unit(r.angles[1]),show(r.ret,4),i?signed(r.ret-sum[0].ret):"—",count(r.done),count(r.screen)]);
    row("elbows",[labels[i],...r.over15.map(count),...r.persistent.map(count)]);
    const f=r.feet;row("contacts",[labels[i],f.samples.toLocaleString(),...f.ratios.map(x=>x==null?"—":show(x,2)+"%"),show(f.peak,2)+" mm",f.speed==null?"—":show(f.speed,2)+" cm/s"]);
    const line=node("div",null,$("angle-chart"));line.className="angle-row";node("span",labels[i],line);
    const bars=node("div",null,line);bars.className="angle-bars";r.angles.forEach((v,j)=>{const b=node("i",null,bars);b.style.width=(100*v/angleMax)+"%";b.setAttribute("aria-label",["源到参考","参考到实际","源到实际"][j]+unit(v));node("b",unit(v),b);});
  });
  $("summary").textContent=(index<0?"全部 40 条动作":clips[0].id)+" · 肩肘都加、锁住下身并复查几何后，整段回报 "+show(sum[0].ret,4)+" → "+show(sum[5].ret,4)+"，完成 "+sum[0].done+" → "+sum[5].done+" 条。";
  const repaired=clips.map(c=>guardedRefs.get(c.id)).filter(c=>c.arm_repair);
  $("repair-result").textContent=repaired.length?repaired.map(c=>{
    const r=c.arm_repair;
    return short(c.id)+" 的手臂修正保留 "+show(100*r.fraction,2)+"%，整段最大自穿透由 "+show(1000*r.initial_peak_m,2)+" mm 降至 "+show(1000*c.screen.maximum_self_penetration_m,2)+" mm，原版为 "+show(1000*r.baseline_peak_m,2)+" mm。";
  }).join(" ")+" 触发重新求解 "+repaired.length+"/"+n+" 条。":"此范围内所有动作均保留完整的手臂修正。";
  renderPair(clips.find(c=>c.pair_contact_traces.length));
  $("angles-note").textContent=common.toLocaleString()+" 个共同执行步。柱长表示角误差，越短越接近目标。";
  $("foot-note").textContent="最深穿透取所有支撑足帧的最大值。滑速只计连续近地支撑，有效样本数按表中顺序为 "+sum.map(v=>v.feet.slip.toLocaleString()).join(" / ")+"。";
  const baseline=sum[0].feet,locked=sum[5].feet;
  $("contact-result").textContent=baseline.samples&&locked.samples?"几何复查方案与原版对照 · 触地 "+show(baseline.ratios[0],2)+"% → "+show(locked.ratios[0],2)+"%，离地超过 20 mm "+show(baseline.ratios[2],2)+"% → "+show(locked.ratios[2],2)+"%，滑速 "+show(baseline.speed,2)+" → "+show(locked.speed,2)+" cm/s。":"此范围内没有标记为支撑的足帧。";
  const m=Number($("candidate").value), changes=clips.map(c=>({c,v:c.variants[m],b:c.variants[0]}));
  const names=a=>a.map(x=>short(x.c.id)).join("、")||"无";
  $("changes").textContent="新完成："+names(changes.filter(x=>x.v.completed&&!x.b.completed))+"。转为提前停止："+names(changes.filter(x=>!x.v.completed&&x.b.completed))+"。";
  const rejected=changes.filter(x=>x.b.screen&&!x.v.screen);
  $("gates").textContent="参考筛查新增失败 · "+(rejected.map(x=>short(x.c.id)+"（"+x.v.reasons.map(r=>reasons[r]??r).join("、")+"）").join("、")||"无")+"。";
  if(m===4){
    const peak=rejected.map(x=>lockedScreens.get(x.c.id)).filter(x=>x.reasons.includes("self_collision"))
      .sort((a,b)=>b.maximum_self_penetration_m-a.maximum_self_penetration_m)[0];
    if(peak)$("gates").textContent+=" 最深自碰撞发生在第 "+peak.maximum_self_penetration_frame+" 帧，穿透 "+show(1000*peak.maximum_self_penetration_m,1)+" mm。";
  }
  const footKey=$("feet-scope").value;
  if(footKey==="physical_feet" && clips.length>1){
    const worse=clips.filter(c=>{
      const a=c.variants[0][footKey],b=c.variants[5][footKey];
      return a.samples>0 && b.samples>0 && b.near/b.samples<a.near/a.samples;
    }).length;
    $("contact-result").textContent+=" 其中 "+worse+"/"+n+" 条动作的近地比例低于原版。";
  }
  changes.sort((x,y)=>Math.abs(y.v.normalized_return-y.b.normalized_return)-Math.abs(x.v.normalized_return-x.b.normalized_return));
  for(const {c,v,b} of changes){
    const tr=row("motion-list",[null,show(b.normalized_return,4),show(v.normalized_return,4),signed(v.normalized_return-b.normalized_return),b.steps+"/"+c.expected_steps,v.steps+"/"+c.expected_steps,v.screen?"通过":v.reasons.map(s=>reasons[s]??s).join("、")]);
    const button=node("button",short(c.id),tr.firstChild);button.onclick=()=>{$("scope").selectedIndex=report.clips.indexOf(c)+1;render();$("scope").scrollIntoView({block:"center"});};
  }
}
async function start(){
  const res=await fetch(new URL("./heldout/arm-ik/results.json",document.baseURI));
  if(!res.ok)throw Error("读取实验结果失败 "+res.status);
  report=await res.json();
  if(report.format!=="moonrobo.arm-ik-study.v1"||report.clips.length!==40||report.runs.map(r=>r.mode).join()!==modes.join())throw Error("评测清单不匹配");
  const locked=await fetch(new URL("./heldout/arm-ik/arms-only/references.json",document.baseURI));
  if(!locked.ok)throw Error("读取参考筛查失败 "+locked.status);
  const refs=await locked.json();
  if(refs.panel_sha256!==report.panel_sha256||refs.clips.length!==report.clips.length)throw Error("筛查与动作清单不匹配");
  lockedScreens=new Map(refs.clips.map(c=>[c.id,c.screen]));
  const checked=await fetch(new URL("./heldout/arm-ik/arms-guarded/references.json",document.baseURI));
  if(!checked.ok)throw Error("读取几何复查结果失败 "+checked.status);
  const evidence=await checked.json();
  if(evidence.panel_sha256!==report.panel_sha256||evidence.clips.length!==report.clips.length||
    evidence.clips.some((c,i)=>c.id!==report.clips[i].id||c.reference_sha256!==report.clips[i].variants[5].reference_sha256))throw Error("复查与动作清单不匹配");
  guardedRefs=new Map(evidence.clips.map(c=>[c.id,c]));
  for(const [i,mode] of modes.entries()){
    const line=node("p",labels[i]+" · ",$("raw-reports"));
    node("a","参考筛查",line).href="./heldout/arm-ik/"+mode+"/references.json";line.append(" · ");
    node("a","完整评测",line).href="./heldout/arm-ik/"+mode+"/final.json";
  }
  const picker=$("scope");picker.replaceChildren(new Option("全部 40 条动作",""));
  report.clips.forEach(c=>picker.add(new Option(c.id,c.id)));
  const wanted=new URL(location.href).searchParams.get("motion");
  picker.selectedIndex=1+report.clips.findIndex(c=>c.id===wanted||short(c.id)===wanted);
  picker.disabled=false;picker.onchange=$("feet-scope").onchange=$("candidate").onchange=render;render();$("results").hidden=false;
}
start().catch(e=>{$("status").textContent=e.message;});

async function showFineTune() {
  const load = async file => {
    const response = await fetch("./heldout/arm-ik/finetune/" + file);
    if (!response.ok) throw Error("微调实验数据暂时无法读取。");
    return response.json();
  };
  const [result, tracking] = await Promise.all([load("result.json"), load("tracking.json")]);
  for (const [label, data] of [["原 40 条（回归）", result.development40], ["新增 21 条（留出）", result.fresh21]]) {
    row("finetune-scores", [label, show(data.baseline_mean_return, 4), show(data.candidate_mean_return, 4),
      signed(data.paired_return_delta), data.baseline_completed + "/" + data.motions, data.candidate_completed + "/" + data.motions]);
  }
  const changes = [...result.development_motions, ...result.fresh_motions].filter(m => m.baseline_completed !== m.candidate_completed);
  $("finetune-changes").textContent = changes.map(m => short(m.motion) + " " + m.baseline_steps.toLocaleString("zh-CN") +
    " → " + m.candidate_steps.toLocaleString("zh-CN") + " 步").join("。") + "。";
  const [a,b] = tracking.right_shoulder_tracking_rmse_deg;
  $("finetune-tracking").textContent = "原 40 条中，两版共同执行了 " + tracking.common_steps.toLocaleString("zh-CN") +
    " 步。右肩相对参考的朝向 RMS 从 " + show(a, 2) + "° 变为 " + show(b, 2) + "°。";
  const feet = tracking.foot_stance_common;
  const near = feet.map(f => show(100 * f.near / f.samples, 2) + "%");
  const speed = feet.map(f => show(50 * f.slip_distance_m / f.slip_samples, 3));
  $("finetune-feet").textContent = "共同时间窗内，支撑脚距地 ≤ 2 mm 的占比从 " + near[0] + " 变为 " + near[1] +
    "，近地支撑脚的平均滑速从 " + speed[0] + " 变为 " + speed[1] + " m/s。";
  function updateReplay() {
    const link = new URL(replay);
    const selected = $("scope").disabled ? new URL(location.href).searchParams.get("motion") : $("scope").value;
    link.searchParams.set("motion", short(selected || "karate/M_Move3"));
    link.searchParams.set("e1", "arm-ft100");
    $("finetune-replay").href = link;
  }
  $("scope").addEventListener("change", updateReplay);
  updateReplay();
}
showFineTune().catch(error => { $("finetune-status").textContent = error.message; });
