import evidence from "virtual:orientation-evidence";
import {bodyNames, controlHz, firstPersistent, frameErrors, frameWidth, orientations, radToDeg} from "./orientation-math.js";

const $ = id => document.getElementById(id);
const short = id => id.split("/").at(-1);
const fixed = x => x.toFixed(5);
const signed = x => (x >= 0 ? "+" : "−") + fixed(Math.abs(x));
const colors = ["#986416","#00756b","#a44632","#4f62a3"];
const seriesNames = ["源 → E1 参考","E1 参考 → E1 实际","源 → E1 实际","源 → G1 实际"];
const anatomicalNames = ["源动作","E1 参考","E1 实际","G1 实际"];
const root = new URL("./heldout/orientation/",document.baseURI);
const back = new URL($("back").href);
const workflow = new URL($("workflow").href);
const clips = evidence.clips;
const el = (type,text,parent) => {
  const node=document.createElement(type); if(text!=null)node.textContent=text;
  parent?.append(node); return node;
};
const row = (parent,label,cells) => {
  const tr=el("tr",null,parent); el("th",label,tr).scope="row";
  for(const v of cells)el("td",v,tr); return tr;
};
const requested = new URLSearchParams(location.search);
let clip, raw, angles, request, body=0, traces;
function locationFor(url,frame) {
  const dest=new URL(url); dest.searchParams.set("motion",short(clip.id));
  dest.searchParams.delete("body");dest.searchParams.delete("step");
  if(frame!=null)dest.searchParams.set("step",String(frame));
  return dest;
}
function renderSummary(){
  const all=$("scope").value==="all";
  const group=all?clips:[clip];
  const mean=fn=>group.reduce((s,c)=>s+fn(c),0)/group.length;
  const gap=mean(c=>c.scores[3]-c.scores[1]);
  const fit=mean(c=>c.ceiling-c.scores[0]),follow=mean(c=>c.scores[0]-c.scores[2]);
  const parts=bodyNames.map((name,b)=>({name,g:mean(c=>c.parts[b].gap)})).sort((a,b)=>b.g-a.g);
  $("overview").replaceChildren();
  for(const [label,value,note] of [
    ["原评测的朝向分差",signed(gap),"G1 减 E1 · 各自参考"],
    ["贡献最大的部位",parts[0].name,signed(parts[0].g)+" 分"],
    ["源目标下的 E1 损失",fixed(fit+follow),"满分姿态减实际姿态"],
  ]){
    const tile=el("div",null,$("overview"));tile.className="tile";
    el("span",label,tile);el("strong",value,tile);el("small",note,tile);
  }
  const frames=group.reduce((s,c)=>s+c.steps,0);
  $("overview-note").textContent=(all?"40 条动作":"所选动作 "+short(clip.id))+" · "+frames.toLocaleString()+" 个共同执行步。以下两张对照表使用同一统计范围，逐帧图始终显示所选动作。";
  $("replace").replaceChildren();
  row($("replace"),"源姿态（理想跟踪）",[fixed(mean(c=>c.ceiling)),"—"]);
  row($("replace"),"替换为 E1 参考",[fixed(mean(c=>c.scores[0])),signed(fit)]);
  row($("replace"),"替换为 E1 实际",[fixed(mean(c=>c.scores[2])),signed(follow)]);
  $("loss-note").textContent="这两步损失合计 "+fixed(fit+follow)+"。第一步是假设能完美跟踪参考的几何对照，第二步含策略、机体动力学和实际接触的共同影响。";
  $("shares").replaceChildren();
  const max=Math.max(...parts.map(p=>Math.abs(p.g)),1e-12);
  for(const {name,g} of parts){
    const line=el("div",null,$("shares"));line.className="share";el("span",name,line);
    const lane=el("span",null,line),bar=el("i",null,lane);bar.style.width=(100*Math.abs(g)/max)+"%";
    if(g<0)bar.style.background=colors[2];el("output",signed(g),line);
  }
  const source=$("factor-goal").value==="source";
  const s=[0,1,2,3].map(j=>mean(c=>(source?c.controls.sourceScores:c.controls.scores)[j]));
  $("factor").replaceChildren();
  row($("factor"),"旧绑定（肘 0°）",[fixed(s[0]),fixed(s[2]),signed(s[2]-s[0])]);
  row($("factor"),"解剖绑定（肘 90°）",[fixed(s[1]),fixed(s[3]),signed(s[3]-s[1])]);
  row($("factor"),"仅换绑定",[signed(s[1]-s[0]),signed(s[3]-s[2]),"—"]);
  const n=group.reduce((s,c)=>s+c.controls.common,0);
  $("factor-note").textContent=(source?"四组实际姿态都对同一个源动作打分。":"按 E1 对各自参考的朝向奖励计分。")+"取 G1 和四组 E1 都还在执行的 "+n.toLocaleString()+" 步。两套策略的换绑定收益相差 "+signed(s[3]-s[2]-s[1]+s[0])+" 分（交互项）。";
}

function onset(channel,b){return firstPersistent(angles[channel][b],Number($("limit").value));}
function renderTable(){
  const target=$("onsets");target.replaceChildren();
  const sorted=clip.parts.map((p,b)=>({p,b})).sort((a,b)=>b.p.gap-a.p.gap);
  $("onset-note").textContent=short(clip.id)+" · 点击帧号跳到曲线及同步回放。第 0 帧是复位姿态，横线表示共同执行段内未持续越线。";
  for(const {p,b} of sorted){
    const tr=row(target,bodyNames[b],[signed(p.gap),...p.squares.slice(0,2).map(x=>(Math.sqrt(x)*radToDeg).toFixed(1)+"°")]);
    if(b===body)tr.className="selected";
    for(let j=0;j<3;j++){
      const f=onset(j,b), td=el("td",null,tr);
      if(f==null)td.textContent="—";
      else {const a=el("button",String(f),td);a.title=bodyNames[b]+" · "+seriesNames[j]+" · "+(f/50).toFixed(2)+" s";
        a.onclick=()=>{selectBody(b,f);$("trace-title").scrollIntoView({block:"start"});};}
    }
  }
}

const svgNS="http://www.w3.org/2000/svg";
function svg(parent,tag,attrs,text){
  const v=document.createElementNS(svgNS,tag);
  for(const [k,val] of Object.entries(attrs))v.setAttribute(k,String(val));
  if(text!=null)v.textContent=text;parent.append(v);return v;
}
function renderPlot(){
  const graph=$("plot");graph.replaceChildren();traces=angles.map(group=>group[body]);
  const hi=Math.max(30,Math.ceil(Math.max(...traces.map(t=>t.reduce((peak,x)=>Math.max(peak,x),0)))/30)*30);
  const x=f=>44+758*f/clip.steps, y=d=>158-144*d/hi;
  for(let i=0;i<=3;i++){const deg=hi*i/3;svg(graph,"line",{x1:44,x2:802,y1:y(deg),y2:y(deg),stroke:"#dce4e2"});
    svg(graph,"text",{x:38,y:y(deg)+4,"text-anchor":"end"},deg+"°");}
  for(let i=0;i<=4;i++){const f=Math.round(clip.steps*i/4);
    svg(graph,"text",{x:x(f),y:181,"text-anchor":i===4?"end":i===0?"start":"middle"},(f/controlHz).toFixed(1)+" s");}
  svg(graph,"line",{x1:44,x2:802,y1:y(+$("limit").value),y2:y(+$("limit").value),stroke:"#899591","stroke-dasharray":"2 4"});
  traces.forEach((t,k)=>{
    const points=t.map((v,f)=>x(f).toFixed(2)+","+y(v).toFixed(2));
    svg(graph,"polyline",{points:points.join(" "),fill:"none",stroke:colors[k],"stroke-width":k===1?1.8:1.45,"stroke-dasharray":["","", "6 2","2 2"][k]});
  });
  svg(graph,"line",{id:"cursor",y1:10,y2:158,stroke:"#223d39","stroke-width":1.5});
  $("trace-title").textContent=short(clip.id)+" · "+bodyNames[body];
  $("plot-caption").textContent="角度越大，姿态偏离越远。虚线阈值 "+$("limit").value+"°。共同执行至第 "+clip.steps+" 帧，共 "+(clip.steps/controlHz).toFixed(2)+" s。";
}
function renderTriads(f){
  const sets=orientations(raw,f);const target=$("triads");target.replaceChildren();
  // World-frame axes projected with the same fixed isometric camera.
  for(const [k,qs] of sets.entries()){
    const [w,x,y,z]=qs[body];
    const axes=[[1-2*(y*y+z*z),2*(x*y+w*z),2*(x*z-w*y)],
      [2*(x*y-w*z),1-2*(x*x+z*z),2*(y*z+w*x)],
      [2*(x*z+w*y),2*(y*z-w*x),1-2*(x*x+y*y)]];
    const fig=el("figure",null,target),pic=svg(fig,"svg",{viewBox:"0 0 64 54","aria-hidden":"true"});
    const ac=["#b74932","#007969","#4566a6"];
    for(let j=0;j<3;j++){const [a,b,c]=axes[j],px=32+20*(.7071*a-.7071*b),py=27+20*(.4082*a+.4082*b-.8165*c);
      svg(pic,"line",{x1:32,y1:27,x2:px,y2:py,stroke:ac[j],"stroke-width":2});svg(pic,"circle",{cx:px,cy:py,r:2,fill:ac[j]});}
    el("figcaption",anatomicalNames[k],fig);fig.title="世界坐标中的部位三轴 · X 红 / Y 绿 / Z 蓝。曲线另补偿相对根部航向。";
  }
}
function renderCursor(){
  if(!raw)return;
  const f=+$("frame").value, x=44+758*f/clip.steps;
  $("cursor").setAttribute("x1",x);$("cursor").setAttribute("x2",x);
  $("reading").textContent="第 "+f+" 帧 · "+(f/controlHz).toFixed(2)+" s";
  $("frame").setAttribute("aria-valuetext",$("reading").textContent);
  document.querySelectorAll("#legend output").forEach((v,j)=>v.textContent=traces[j][f].toFixed(1)+"°");
  $("replay").href=locationFor(back,f);

  renderTriads(f);
}
function shareSelection(){
  const url=locationFor(location.href,+$("frame").value);url.searchParams.set("body",evidence.e1_bodies[body]);history.replaceState(null,"",url);
}
function selectBody(b,frame){
  body=b;$("body").value=String(b);
  $("frame").value=frame??onset(1,b)??0;
  renderTable();renderPlot();renderCursor();shareSelection();
}
async function selectClip(index, initial=false){
  request?.abort(); const controller=new AbortController();request=controller;
  raw=null;angles=null;clip=clips[index];$("trace-title").textContent=short(clip.id);
  document.querySelectorAll("#legend output").forEach(v=>v.textContent="");$("plot-caption").textContent="";$("notice").textContent="正在核对逐帧姿态…";
  for(const id of ["plot","triads","onsets","reading"])$(id).replaceChildren();
  $("body").disabled=$("frame").disabled=$("limit").disabled=true;$("replay").hidden=true;
  const dest=locationFor(location.href);history.replaceState(null,"",dest);$("back").href=locationFor(back);$("workflow").href=locationFor(workflow);
  $("raw").href=new URL(index+".f32",root);
  renderSummary();
  try{
    const res=await fetch($("raw").href,{signal:controller.signal});
    if(!res.ok)throw Error("HTTP "+res.status);
    const buf=await res.arrayBuffer();
    const digest=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",buf)),x=>x.toString(16).padStart(2,"0")).join("");
    if(controller.signal.aborted)return;
    if(digest!==clip.sha256||buf.byteLength!==(clip.steps+1)*4*frameWidth)throw Error("姿态文件校验失败");
    raw=new Float32Array(buf);angles=Array.from({length:4},()=>bodyNames.map(()=>[]));
    for(let f=0;f<=clip.steps;f++){
      frameErrors(raw,f).forEach((channel,k)=>channel.forEach((ang,b)=>angles[k][b].push(ang*radToDeg)));
    }
    $("frame").max=clip.steps;
    const biggest=clip.parts.reduce((top,p,i)=>p.gap>clip.parts[top].gap?i:top,0);
    const named=initial?evidence.e1_bodies.indexOf(requested.get("body")):-1;
    const value=initial&&requested.has("step")?Number(requested.get("step")):NaN;
    selectBody(named>=0?named:biggest,Number.isInteger(value)&&value>=0&&value<=clip.steps?value:undefined);$("body").disabled=$("frame").disabled=$("limit").disabled=false;$("replay").hidden=false;$("notice").textContent="";
  }catch(e){if(!controller.signal.aborted)$("notice").textContent="无法读取该动作。"+e.message;}
}
for(const [j,name] of seriesNames.entries()){const item=el("span",null,$("legend"));const key=el("i",null,item);key.style.borderColor=colors[j];if(j>=2)key.style.borderTopStyle=j===2?"dashed":"dotted";item.append(name+" ");el("output","",item);}
clips.forEach((c,i)=>$("motion").add(new Option(c.id,String(i))));
bodyNames.forEach((s,i)=>$("body").add(new Option(s,String(i))));
const wanted=new URL(location.href).searchParams.get("motion")??"M_Move3";
$("motion").selectedIndex=Math.max(0,clips.findIndex(c=>c.id===wanted||short(c.id)===wanted));
$("motion").onchange=()=>selectClip($("motion").selectedIndex);
$("body").onchange=()=>selectBody(+$("body").value);
$("scope").onchange=renderSummary;
$("factor-goal").onchange=renderSummary;
$("limit").onchange=()=>{renderTable();renderPlot();renderCursor();};
$("frame").oninput=renderCursor;$("frame").onchange=shareSelection;
selectClip($("motion").selectedIndex,true);
