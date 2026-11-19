///|
pub fn supported_kernels() -> Array[String] {
  [
    "newton-done", "cg-beta-finalize", "newton-done-with-ls", "cg-beta-search-finalize",
  ]
}

///|
fn entry(request : Request, key : String) -> Entry raise {
  guard supported_kernels().contains(key) else {
    fail("unsupported device convergence transition")
  }
  let parameters = [
    parameter("opt_tolerance", "float32", 1, "input"),
    parameter("stat_meaninertia", "float32", 1, "input"),
  ]
  let cg = key == "cg-beta-finalize" || key == "cg-beta-search-finalize"
  if cg {
    for name in ["ctx_grad", "ctx_Mgrad", "ctx_prev_grad", "ctx_prev_Mgrad"] {
      parameters.push(
        parameter(
          name,
          "float32",
          2,
          if key == "cg-beta-search-finalize" &&
            (name == "ctx_prev_grad" || name == "ctx_prev_Mgrad") {
            "inout"
          } else {
            "input"
          },
        ),
      )
    }
  }
  for name in ["ctx_grad_dot", "ctx_improvement", "ctx_alpha"] {
    parameters.push(parameter(name, "float32", 1, "input"))
  }
  if !cg {
    parameters.push(parameter("ctx_newton_decrement", "float32", 1, "input"))
  }
  for name in ["solver_niter", "overflow", "nsolving"] {
    parameters.push(parameter(name, "int32", 1, "inout"))
  }
  parameters.push(parameter("ctx_done", "bool", 1, "inout"))
  if cg {
    parameters.push(parameter("ctx_beta", "float32", 1, "output"))
  }
  if key == "newton-done-with-ls" || key == "cg-beta-search-finalize" {
    parameters.push(parameter("ls_overflow", "int32", 1, "input"))
  }
  if key == "cg-beta-search-finalize" {
    parameters.push(parameter("ctx_search", "float32", 2, "inout"))
    parameters.push(parameter("ctx_search_dot", "float32", 1, "output"))
  }
  {
    key,
    forward: "mr_mjw_convergence_" + key.replace_all(old="-", new="_"),
    launch_shape: [request.nworld],
    parameters,
  }
}

///|
fn body(request : Request, key : String) -> String {
  let beta = if key == "cg-beta-finalize" || key == "cg-beta-search-finalize" {
    "float num=0.0f,den=0.0f;\nfor(int dofid=0;dofid<\{request.nv};dofid++){\nfloat prev=wp::index(ctx_prev_Mgrad,worldid,dofid);\nnum+=wp::index(ctx_grad,worldid,dofid)*(wp::index(ctx_Mgrad,worldid,dofid)-prev);\nden+=wp::index(ctx_prev_grad,worldid,dofid)*prev;\n}\nwp::index(ctx_beta,worldid)=wp::max(0.0f,num/wp::max(1.0e-15f,den));\n"
  } else {
    ""
  }
  let newton = if key == "newton-done" || key == "newton-done-with-ls" {
    "float model_improvement=(0.5f*wp::index(ctx_newton_decrement,worldid))/denominator;\ndone=done || model_improvement<tolerance;\n"
  } else {
    ""
  }
  // The upstream input/output done descriptors designate the same array. The
  // merged inout parameter makes that exact alias explicit in the public ABI.
  let ls = if key == "newton-done-with-ls" || key == "cg-beta-search-finalize" {
    "wp::index(overflow,worldid)=wp::index(overflow,worldid)|wp::index(ls_overflow,worldid);\n"
  } else {
    ""
  }
  let search = if key == "cg-beta-search-finalize" {
    "if(!wp::index(ctx_done,worldid)){float norm=0.0f,beta=wp::index(ctx_beta,worldid);for(int dofid=0;dofid<\{request.nv};dofid++){float mgrad=wp::index(ctx_Mgrad,worldid,dofid),value=-mgrad+beta*wp::index(ctx_search,worldid,dofid);wp::index(ctx_search,worldid,dofid)=value;norm+=value*value;wp::index(ctx_prev_grad,worldid,dofid)=wp::index(ctx_grad,worldid,dofid);wp::index(ctx_prev_Mgrad,worldid,dofid)=mgrad;}wp::index(ctx_search_dot,worldid)=norm;}\n"
  } else {
    ""
  }
  "if(wp::index(ctx_done,worldid))continue;\n" +
  ls +
  beta +
  "wp::index(solver_niter,worldid)+=1;\nfloat tolerance=wp::index(opt_tolerance,worldid%opt_tolerance.shape[0]);\nfloat meaninertia=wp::index(stat_meaninertia,worldid%stat_meaninertia.shape[0]);\nfloat denominator=meaninertia*float(\{request.nv});\nfloat improvement=wp::index(ctx_improvement,worldid)/denominator;\nfloat gradient=wp::sqrt(wp::index(ctx_grad_dot,worldid))/denominator;\nbool done=wp::index(ctx_alpha,worldid)==0.0f || (improvement>0.0f && improvement<tolerance) || gradient<tolerance;\n" +
  newton +
  "if(done || wp::index(solver_niter,worldid)==\{request.iterations}){\nif(!done && wp::index(solver_niter,worldid)==\{request.iterations})wp::index(overflow,worldid)=wp::index(overflow,worldid)|512;\nwp::index(ctx_done,worldid)=true;\nwp::atomic_add(nsolving,0,-1);\n}\n" +
  search
}

///|
/// Generates real convergence arithmetic and device condition updates. It
/// neither generates a line search/gradient solve nor fabricates their inputs.
pub fn lower(request : Request) -> Lowered raise {
  guard request.nworld > 0 &&
    request.nworld <= 1000000 &&
    request.nv > 0 &&
    request.nv <= 1000000 &&
    request.nworld <= 2147483647 / request.nv &&
    request.iterations > 0 &&
    request.iterations <= 1000000 &&
    request.warn_overflow == 0 &&
    !request.kernels.is_empty() else {
    fail(
      "device convergence dimensions/iterations invalid; warning printf variants unsupported",
    )
  }
  let entries : Array[Entry] = []
  let seen : Map[String, Unit] = {}
  let blocks = [
    "// Copyright 2026 The Newton Developers\n// SPDX-License-Identifier: Apache-2.0\n// MuJoCo-Warp 3.15 solver convergence transitions; serial FP32 per-world CG reduction.\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56 && sizeof(bool)==1,\"Warp 1.17 64-bit ABI required\");\n",
  ]
  for key in request.kernels {
    guard !seen.contains(key) else {
      fail("duplicate device convergence kernel")
    }
    seen[key] = ()
    let selected = entry(request, key)
    entries.push(selected)
    blocks.push(
      "extern \"C\" __global__ void " +
      selected.forward +
      "(wp::launch_bounds_t<1> dim," +
      selected.parameters.map(p => p.c_type + " " + p.name).join(",") +
      "){\nfor(size_t linear=size_t(blockIdx.x)*blockDim.x+threadIdx.x;linear<dim.size;linear+=size_t(blockDim.x)*gridDim.x){\nint worldid=int(linear);\n" +
      body(request, key) +
      "}\n}\n",
    )
  }
  let source = blocks.join("\n")
  let generated_sha = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-device-convergence-specialization-v1",
    "request": request.to_json(),
    "entries": entries.to_json(),
    "source_sha256": Json(generated_sha),
    "upstream_solver_sha256": Json(source_sha256()),
    "warp_version": "1.17.0",
  }
  {
    request,
    source,
    source_sha256: generated_sha,
    specialization_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    entries,
  }
}
