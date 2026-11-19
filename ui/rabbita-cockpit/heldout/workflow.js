import { validatePanel, robots } from "./playback.js";

const $ = id => document.getElementById(id);
const fixed = (v, digits=4) => v.toFixed(digits);
const signed = (v, digits=4) => (v >= 0 ? "+" : "−") + fixed(Math.abs(v), digits);
const title = id => id.split("/")[1];
const labels = ["身体位置","身体朝向","身体线速度","身体角速度","根部位置","根部朝向","动作变化惩罚","关节限位惩罚"];
const base = new URL("./heldout/", document.baseURI);
const replayURL = new URL($("replay-link").href);
let panel, workflow, active, request;

function tag(kind, text, parent, className) {
  const el = document.createElement(kind);
  if (text != null) el.textContent = text;
  if (className) el.className = className;
  parent.append(el);
  return el;
}

async function load(path, type, signal) {
  const res = await fetch(new URL(path, base), {signal});
  if (!res.ok) throw Error("读取数据失败 " + res.status);
  return res[type]();
}

function overview() {
  const n = panel.clips.length;
  const avg = values => values.reduce((a,b) => a+b, 0) / n;
  const delta = k => avg(workflow.clips.map(c => c.g1[k] - c.e1[k]));
  const scores = robots.map(r => avg(panel.clips.map(c => c[r].score)));
  const completed = robots.map(r => panel.clips.filter(c => c[r].completed).length);
  const shared = delta("shared"), tail = delta("tail"), gap = scores[0] - scores[1];
  if (Math.abs(shared + tail - gap) > 1e-7) throw Error("累计分差核对失败");
  const passed = workflow.clips.filter(c => c.screen_passed).length;
  const items = [
    ["整段回报差", signed(gap), "G1 " + fixed(scores[0]) + " · E1 " + fixed(scores[1])],
    ["双方都在执行时", signed(shared), "占总差 " + fixed(100*shared/gap,1) + "%"],
    ["一方停止后", signed(tail), "完成数 G1 " + completed[0] + "/40 · E1 " + completed[1] + "/40"],
  ];
  for (const [label, value, detail] of items) {
    const tile = tag("div", null, $("overview"), "tile");
    tag("span", label, tile); tag("strong", value, tile); tag("small", detail, tile);
  }
  const note=tag("p", "每条动作等权，差值均为 G1 减 E1。E1 几何筛查通过 "+passed+"/40。", $("overview").parentElement);
  note.className="overview-note";
}

async function readTrack(meta, steps, expectedScore, denominator, signal) {
  const bytes = await load("workflow/" + meta.file, "arrayBuffer", signal);
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2,"0")).join("");
  if (hash !== meta.sha256 || bytes.byteLength !== steps*44) throw Error("逐步记录与动作不匹配");
  const data = new DataView(bytes), sums = new Float64Array(steps+1);
  const at = (step, col) => data.getFloat32(((step-1)*11+col)*4,true);
  for (let s=1;s<=steps;s++) sums[s] = sums[s-1] + at(s,0)/denominator;
  if (Math.abs(sums[steps]-expectedScore)>1e-7) throw Error("逐步回报与已发布分数不符");
  return { at, sums };
}

function renderStages() {
  const {clip:c, detail:d, common} = active;
  const diff = key => signed(d.g1[key] - d.e1[key]);
  const stages = [
    ["输入与训练", d.source_frames.toLocaleString() + " 帧 · 同一源动作",
      "G1 Moves "+workflow.source_hz+" Hz → 控制 "+panel.control_hz+" Hz。训练目录 G1 " + workflow.g1_catalog.toLocaleString() + " 条，E1 " + workflow.e1_train + " 条。双方目录与留出集的动作 ID 和源哈希重合均为 0。"],
    ["参考重定向", "G1 原生 29 轴 → E1 拟合 23 轴",
      "E1 身体目标 RMS " + fixed(d.body_rms_m*100,2) + " cm，前臂方向平均误差 " + fixed(d.arm.mean_world_forearm_error_deg,1) + "°。" +
      (d.screen_passed ? "通过几何筛查。" : "超限项：" + d.screen_reasons.map(x => ({task_body_rms:"身体 RMS", stance_position:"支撑足位置", sole_penetration:"足底穿透"})[x] || x).join("、") + "。")],
    ["共同执行", "前 " + fixed(common/panel.control_hz,2) + " s · " + diff("shared"),
      "相同的 " + common.toLocaleString() + " 步内，G1 已赚取 " + fixed(d.g1.shared) + "，E1 已赚取 " + fixed(d.e1.shared) + "。均除以整段满分。"],
    ["停止与结算", "后续 " + diff("tail") + " → 总差 " + signed(c.g1.score - c.e1.score),
      robots.map(r=>r.toUpperCase()+" 在 "+ fixed(c[r].steps/panel.control_hz,2)+" s "+(c[r].completed?"完成":"停止")).join("，")+"。"],
  ];
  $("stages").replaceChildren();
  for (const [i,[label,metric,body]] of stages.entries()) {
    const li = tag("li",null,$("stages")), h = tag("h3",null,li);
    tag("span",String(i+1).padStart(2,"0"),h); h.append(label);
    tag("b",metric,li); tag("p",body,li);
  }
}

function renderDetails() {
  const {clip,detail,tracks}=active;
  renderTerms();
  $("stops").replaceChildren();
  for (const r of robots) {
    const {steps,completed}=clip[r];
    const z=tracks[r].at(steps,1), tilt=tracks[r].at(steps,2);
    const block=tag("div",null,$("stops"),"outcome");
    tag("h3",r.toUpperCase()+" · "+(completed?"完成动作":"提前终止")+" · 第 "+steps.toLocaleString()+" 步",block);
    const triggers=[z>0.25?"高度":null,tilt>0.8?"倾斜":null].filter(Boolean);
    tag("p","高度误差 "+fixed(z,4)+" m，竖直分量误差 "+fixed(tilt,4)+"。"+(triggers.length?"触发"+triggers.join("和")+"判据。":""),block);
    const rmse=detail[r].rmse;
    tag("p","已执行段 RMS · 关节 "+fixed(rmse.joint_rmse_rad,3)+" rad，根部相对身体位置 "+fixed(rmse.root_relative_body_position_rmse_m*100,2)+" cm。",block);
  }
}

function renderTerms() {
  const scope=$("terms-scope").value;
  const clips=scope==="all"?workflow.clips:[active.detail];
  function average(r,i) {
    if (scope!=="window") return clips.reduce((sum,c)=>sum+c[r].shared_terms[i],0)/clips.length;
    let sum=0;
    for(let s=active.peak-panel.control_hz+1;s<=active.peak;s++) sum+=active.tracks[r].at(s,3+i);
    return sum/(active.clip.expected_steps*0.1);
  }
  const context = scope==="all" ? "40 条动作各自取共同执行段，再等权平均。"
    : scope==="window" ? "所选动作 "+fixed((active.peak-panel.control_hz)/panel.control_hz,2)+"–"+fixed(active.peak/panel.control_hz,2)+" s，双方均在执行。"
    : "所选动作从开始至 "+fixed(active.common/panel.control_hz,2)+" s。";
  $("term-caption").textContent=context+"各项均除以各自动作的整段满分，正值表示 G1 得分较高。";
  $("terms").replaceChildren();
  const rows=labels.map((name,i)=>({name, g:average("g1",i),e:average("e1",i)}));
  for (const {name,g,e} of rows.sort((a,b)=>Math.abs(b.g-b.e)-Math.abs(a.g-a.e))) {
    const tr=tag("tr",null,$("terms"));
    tag("th",name,tr).scope="row";
    for (const v of [fixed(g),fixed(e),signed(g-e)]) tag("td",v,tr);
  }
}

const svgNS = "http://www.w3.org/2000/svg";
function svgNode(type, props, content) {
  const n=document.createElementNS(svgNS,type);
  for(const [key,v] of Object.entries(props)) n.setAttribute(key,String(v));
  if(content!==undefined) n.textContent=content;
  $("plot").append(n); return n;
}

function renderGraph() {
  if (!active) return;
  const {clip,tracks,common}=active, mode=$("metric").value, isReturn=mode==="return";
  const n=clip.expected_steps, hz=panel.control_hz, col=mode==="height"?1:2;
  const val=(r,s) => isReturn ? tracks[r].sums[Math.min(s,clip[r].steps)] : tracks[r].at(s,col);
  const threshold=mode==="height"?0.25:0.8;
  let lo=0,hi=isReturn?0.1:threshold;
  for (const r of robots) for(let s=isReturn?0:1;s<=clip[r].steps;s++){
    const v=val(r,s); lo=Math.min(lo,v); hi=Math.max(hi,v);
  }
  const w=Math.max(290,$("plot").clientWidth),h=190,left=38,right=w-12,top=14,bottom=h-26;
  $("plot").setAttribute("viewBox",`0 0 ${w} ${h}`); $("plot").replaceChildren();
  const X=s=>left+(right-left)*s/n, Y=v=>bottom-(v-lo)/(hi-lo)* (bottom-top);
  const line=(x1,y1,x2,y2,props)=>svgNode("line",{x1,y1,x2,y2,...props});
  for(let i=0;i<4;i++){
    const v=lo+(hi-lo)*i/3;
    line(left,Y(v),right,Y(v),{stroke:"#dce4e2"}); svgNode("text",{x:left-4,y:Y(v)+4,"text-anchor":"end"},fixed(v,2));
  }
  for (const s of [0, Math.round(n/2),n]) svgNode("text",{x:X(s), y:h-6,"text-anchor":s===0?"start":s===n?"end":"middle"},fixed(s/hz,1)+" s");
  if(!isReturn) line(left,Y(threshold),right,Y(threshold),{stroke:"#936b28","stroke-dasharray":"7 4"});
  line(X(common),top,X(common),bottom,{stroke:"#343f42","stroke-dasharray":"2 2"});
  for (const r of robots) {
    const start=isReturn?0:1, end=clip[r].steps;
    // Keep both extrema in each pixel bin so short-lived deviations remain visible.
    const stride=Math.max(1,Math.ceil((end-start)/(right-left)));
    const pts=[];
    const put=s=>pts.push(X(s).toFixed(2)+","+Y(val(r,s)).toFixed(2));
    put(start);
    for(let s=start;s<=end;s+=stride){
      const last=Math.min(end,s+stride-1); let min=s,max=s;
      for(let i=s+1;i<=last;i++){if(val(r,i)<val(r,min))min=i;if(val(r,i)>val(r,max))max=i;}
      put(Math.min(min,max)); if(min!==max)put(Math.max(min,max));
    }
    put(end); if(isReturn && end<n)put(n);
    svgNode("polyline",{points:pts.join(" "), fill:"none",stroke:r==="g1"?"#00685e":"#96401e","stroke-width":2.4,"stroke-dasharray":r==="g1"?"none":"7 3"});
  }
  active.cursor=line(0,top,0,bottom,{stroke:"#74837f","stroke-width":1});
  active.X=X; active.limits=[left,right];
  $("plot-caption").textContent=isReturn?"每步实得奖励除以整段满分后累加。机器人停止后，累计值保持不变。":"误差相对于该机器人自己的参考姿态。虚线阈值对应终止条件，曲线止于最后一个真实步。";
  renderCursor();
}

function renderCursor() {
  const {clip,tracks,X,cursor}=active, s=Number($("frame").value), mode=$("metric").value;
  cursor.setAttribute("x1",X(s));cursor.setAttribute("x2",X(s));
  const values=robots.map(r=>{
    if(mode==="return")return fixed(tracks[r].sums[Math.min(s,clip[r].steps)]);
    if(s===0)return "初始帧";
    if(s>clip[r].steps)return "已停止";
    return fixed(tracks[r].at(s,mode==="height"?1:2))+(mode==="height"?" m":"");
  });
  const when=fixed(s/panel.control_hz,2)+" s · 第 "+s+" 步";
  $("frame").setAttribute("aria-valuetext",when);
  $("reading").textContent=when+"　G1 "+values[0]+"　E1 "+values[1];
  const link=new URL($("replay-link").href);link.searchParams.set("step",s);
  $("frame-link").href=link;
}

async function select(index) {
  request?.abort();
  const controller=new AbortController(); request=controller;
  active=null; $("analysis").hidden=true; $("notice").textContent="读取逐步实测记录…";
  const c=panel.clips[index], d=workflow.clips[index];
  const url=new URL(location.href);url.searchParams.set("motion",title(c.id));history.replaceState(null,"",url);
  const orient=new URL("./orientation.html",location.href);orient.searchParams.set("motion",title(c.id));$("orientation-link").href=orient;
  const back=new URL(replayURL);back.searchParams.set("motion",title(c.id));$("replay-link").href=back;
  try {
    const tracks=Object.fromEntries(await Promise.all(robots.map(async r=>[r,await readTrack(d[r],c[r].steps,c[r].score,c.expected_steps*0.1,controller.signal)])));
    if(controller.signal.aborted)return;
    active={clip:c,detail:d,tracks,common:Math.min(c.g1.steps,c.e1.steps)};
    $("motion-label").textContent=title(c.id)+" · "+fixed(c.expected_steps/panel.control_hz,2)+" s";
    const gapAt=s=>tracks.g1.sums[s]-tracks.e1.sums[s];
    let peak=panel.control_hz;
    for(let end=peak+1;end<=active.common;end++){
      if(Math.abs(gapAt(end)-gapAt(end-panel.control_hz))>Math.abs(gapAt(peak)-gapAt(peak-panel.control_hz))) peak=end;
    }
    active.peak=peak;
    $("peak").title="双方都在执行的连续 1 秒内，累计分差绝对变化最大的一段";
    $("peak").textContent=fixed((peak-panel.control_hz)/panel.control_hz,2)+"–"+fixed(peak/panel.control_hz,2)+" s · 分差变化 "+signed(gapAt(peak)-gapAt(peak-panel.control_hz));
    $("frame").max=c.expected_steps;
    $("frame").value=active.common;
    $("jump").textContent=active.common===c.expected_steps?"跳到动作结束":"跳到首次停止";
    $("analysis").hidden=false; $("notice").textContent="";
    renderStages();renderDetails();renderGraph();
  } catch(error){ if(!controller.signal.aborted)$("notice").textContent=error.message; }
}

async function start(){
  [panel,workflow]=await Promise.all([load("tracks/manifest.json","json").then(validatePanel),load("workflow/manifest.json","json")]);
  if(workflow.format!=="moonrobo.paired-workflow.v1" || workflow.panel_sha256!==panel.panel_sha256 ||
      workflow.clips.length!==panel.clips.length || !panel.clips.every((c,i)=>workflow.clips[i].id===c.id)) throw Error("流程与回放的动作列表不匹配");
  overview();
  const ordered=panel.clips.map((clip,i)=>({clip,i,delta:clip.g1.score-clip.e1.score})).sort((a,b)=>b.delta-a.delta);
  for(const {clip,i,delta} of ordered){
    const d=workflow.clips[i], tr=tag("tr",null,$("ranking"));
    const th=tag("th",null,tr); th.scope="row";
    const a=tag("a",title(clip.id),th);
    const dest=new URL(location.href); dest.searchParams.set("motion",title(clip.id));a.href=dest;
    for (const value of [fixed(d.body_rms_m*100,2)+" cm",signed(d.g1.shared-d.e1.shared),signed(d.g1.tail-d.e1.tail),signed(delta)]) tag("td",value,tr);
  }
  const picker=$("motion");picker.replaceChildren();
  for (const [i,c] of panel.clips.entries()) picker.append(new Option(c.id,String(i)));
  const motion=new URLSearchParams(location.search).get("motion") || "M_Move3";
  const index=panel.clips.findIndex(c=>title(c.id)===motion||c.id===motion);
  picker.selectedIndex=index>=0?index:0; picker.disabled=false; picker.onchange=()=>select(picker.selectedIndex);
  $("terms-scope").onchange=renderTerms; $("metric").onchange=renderGraph; $("frame").oninput=renderCursor;
  $("peak").onclick=()=>{ $("frame").value=active.peak;$("terms-scope").value="window";renderCursor();renderTerms(); };
  $("jump").onclick=()=>{ $("frame").value=active.common;renderCursor(); };
  $("plot").onclick=event=>{
    if(!active)return;
    const [left,right]=active.limits;
    const x=event.clientX-$("plot").getBoundingClientRect().left;
    $("frame").value=Math.round((x-left)/(right-left)*active.clip.expected_steps);renderCursor();
  };
  new ResizeObserver(()=>{if(active)renderGraph();}).observe($("plot"));
  await select(picker.selectedIndex);
}
start().catch(e=>{ $("notice").textContent="无法加载分析。"+e.message; });
