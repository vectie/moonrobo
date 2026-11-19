"""Experimental native export of original SMC imagined-step equations.

Initial and recurrent gradient signatures are separate. All policy parameters,
frozen world weights and running statistics remain explicit live inputs.
No critic/reward/update acceptance is implied by producing these binaries.
"""
import json
import os
from pathlib import Path

import torch
from shared_smc_probe_bf16_original import SharedProbe,unflatten_state,normalize_xi
from export_compiled_world_g import export_pair


def main():
    out=Path(os.environ["MOONROBO_SHARED_OUTPUT"])
    probe=SharedProbe(Path(os.environ["MOONROBO_SHARED_INPUT"]),compiled=False)
    probe.prepare_actor()
    for p in probe.wm.parameters(): p.requires_grad_(False)
    ctx=probe.ctx

    class Step(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.pi,self.wm=probe.pi,probe.wm
            self.register_buffer("reference_rotations",ctx["motion"].root_R)
            self.register_buffer("goals",probe.goals)
            self.register_buffer("noise",probe.noise)
            self.register_buffer("default_q",ctx["mdp"].default_q)

        def forward(self,p,r,v,w,q,qd,history,f,xi,xi_n,goal):
            # The original function's external data is rebound to functional
            # buffers exactly as for the already-validated world exporter.
            motion,mdp=ctx["motion"],ctx["mdp"]
            previous=(motion.root_R,motion.goal,ctx["fixed_noise"],mdp.default_q)
            motion.root_R=self.reference_rotations
            motion.goal=lambda f,k:self.goals[f]
            ctx["fixed_noise"],mdp.default_q=self.noise,self.default_q
            try:
                state,action,hist,_,_=ctx["_imag_step"]((p,r,v,w,q,qd),history,q,f,xi,xi_n,goal)
                # Frame and next-goal outputs have no derivatives and are
                # supplied by the native batch at the next chronological step.
                return (*state,action,hist)
            finally:
                motion.root_R,motion.goal,ctx["fixed_noise"],mdp.default_q=previous

    module=Step()
    parameter_names=[*dict(module.named_parameters())]
    assert parameter_names[:20]==["pi."+n for n,_ in probe.pi.named_parameters()]
    assert len(parameter_names)==34
    buffer_names=["pi.obs_norm.mean","pi.obs_norm.var","pi.goal_norm.mean","pi.goal_norm.var",
        "wm.in_norm.mean","wm.in_norm.var","wm.out_norm.mean","wm.out_norm.var",
        "reference_rotations","goals","noise","default_q"]
    buffers=dict(module.named_buffers())

    def step(*args):
        mapping=dict(zip(parameter_names+buffer_names,args[11:]))
        return torch.func.functional_call(module,mapping,args[:11])

    original=torch._inductor.aot_compile
    def compile_graph(gm,args,*,options):
        if not options["aot_inductor.output_path"].endswith("backward.so"):
            return original(gm,args,options=options)
        from torch._inductor.compile_fx import compile_fx_inner,get_cpp_wrapper_config
        from torch._inductor.virtualized import V
        with torch._inductor.config.patch({**get_cpp_wrapper_config(),**options,"cpp_wrapper":True}),V.set_aot_compilation(True),torch._guards.compile_context(torch._guards.CompileContext(None)):
            return compile_fx_inner(gm,args,cpp_wrapper=True,is_backward=True,is_inference=False).filename

    state=unflatten_state(probe.state)
    f=torch.arange(4096,device="cuda")
    args=[*state,probe.history,f,probe.xi,normalize_xi(probe.xi),probe.goals[:4096],
        *module.parameters(),*(buffers[n] for n in buffer_names)]
    torch._inductor.aot_compile=compile_graph
    try:
        output=step(*args)
        predicted=export_pair(step,args,tuple(torch.ones_like(x) for x in output),out/"initial")
        del output
        args[:6]=[v.requires_grad_() for v in predicted[:6]]
        args[6]=predicted[7].requires_grad_()
        args[7]=f+4096
        args[10]=probe.goals[4096:8192]
        output=step(*args)
        export_pair(step,args,tuple(torch.ones_like(x) for x in output),out/"recurrent")
    finally:
        torch._inductor.aot_compile=original
    torch.cuda.synchronize()
    assert torch.cuda.mem_get_info()[0]>16*1024**3 and torch.cuda.memory_reserved()<32*1024**3
    (out/"result.json").write_text(json.dumps(dict(exported=True,diagnostic_only=True,
        parameter_names=parameter_names,buffer_names=buffer_names,
        original_equations="SharedProbe original _imag_step AST with fixed identical exogenous inputs",
        discarded_outputs="integer next frame and non-differentiable next goal; native supplies both from same batch",
        peak_reserved=torch.cuda.max_memory_reserved()),indent=2))


if __name__=="__main__":main()
