///|
pub fn supported_kernels() -> Array[String] {
  [
    "mass-multiply-sparse", "constraint-force-zero-sparse", "constraint-force-rebuild-sparse",
    "nxn-broadphase",
  ]
}

///|
fn selected(request : Request, key : String) -> Entry raise {
  let (forward, file, function, helpers, shape, parameters) = match key {
    "mass-multiply-sparse" =>
      (
        "mr_mjw_mass_multiply_sparse",
        "support.py",
        "mul_m_kernel",
        [],
        [request.nworld, request.nv],
        [
          parameter("M_mulm_rowadr", "int32", 1, "input"),
          parameter("M_mulm_col", "int32", 1, "input"),
          parameter("M_mulm_madr", "int32", 1, "input"),
          parameter("M_in", "float32", 2, "input"),
          parameter("vec", "float32", 2, "input"),
          parameter("skip", "bool", 1, "input"),
          parameter("res", "float32", 2, "output"),
        ],
      )
    "constraint-force-zero-sparse" =>
      (
        "mr_mjw_constraint_force_zero_sparse",
        "solver.py",
        "_zero_qfrc_constraint_sparse",
        [],
        [request.nworld, request.nv],
        [
          parameter("state_changed_count_in", "int32", 1, "input"),
          parameter("ctx_done_in", "bool", 1, "input"),
          parameter("qfrc_constraint_out", "float32", 2, "output"),
        ],
      )
    "constraint-force-rebuild-sparse" =>
      (
        "mr_mjw_constraint_force_rebuild_sparse",
        "solver.py",
        "_update_constraint_init_qfrc_constraint_sparse",
        [],
        [request.nworld, request.njmax],
        [
          parameter("nefc_in", "int32", 1, "input"),
          parameter("efc_J_rownnz_in", "int32", 2, "input"),
          parameter("efc_J_rowadr_in", "int32", 2, "input"),
          parameter("efc_J_colind_in", "int32", 3, "input"),
          parameter("efc_J_in", "float32", 3, "input"),
          parameter("efc_force_in", "float32", 2, "input"),
          parameter("dof_cdof_in", "int32", 2, "input"),
          parameter("state_changed_count_in", "int32", 1, "input"),
          parameter("ctx_done_in", "bool", 1, "input"),
          parameter("qfrc_constraint_out", "float32", 2, "inout"),
        ],
      )
    "nxn-broadphase" =>
      (
        "mr_mjw_nxn_broadphase",
        "collision_driver.py",
        "_nxn_broadphase",
        [
          "_plane_filter", "_sphere_filter", "_aabb_filter", "_broadphase_filter",
          "_mesh_missing", "_add_geom_pair",
        ],
        [request.nworld, request.npair],
        [
          parameter("geom_type", "int32", 1, "input"),
          parameter("geom_bodyid", "int32", 1, "input"),
          parameter("geom_dataid", "int32", 2, "input"),
          parameter("geom_aabb", "vec3f", 3, "input"),
          parameter("geom_rbound", "float32", 2, "input"),
          parameter("geom_margin", "float32", 2, "input"),
          parameter("geom_gap", "float32", 2, "input"),
          parameter("nxn_geom_pair", "vec2i", 1, "input"),
          parameter("nxn_pairid", "vec2i", 1, "input"),
          parameter("geom_xpos_in", "vec3f", 2, "input"),
          parameter("geom_xmat_in", "mat33f", 2, "input"),
          parameter("body_awake_in", "int32", 2, "input"),
          scalar("naconmax_in"),
          parameter("body_awake_prev_in", "int32", 2, "input"),
          parameter("ncollision_out", "int32", 1, "inout"),
          parameter("collision_pair_out", "vec2i", 1, "output"),
          parameter("collision_pairid_out", "vec2i", 1, "output"),
          parameter("collision_worldid_out", "int32", 1, "output"),
        ],
      )
    _ =>
      raise Unsupported::Invalid("unsupported concrete physics kernel: " + key)
  }
  {
    key,
    forward,
    source_file: file,
    source_function: function,
    source_sha256: source_sha(file),
    helper_functions: helpers,
    launch_shape: shape,
    parameters,
  }
}

///|
fn validate(request : Request) -> Unit raise {
  guard request.nworld > 0 &&
    request.nv > 0 &&
    request.nworld <= 2147483647 / request.nv &&
    request.ngeom >= 0 &&
    request.npair >= 0 &&
    request.njmax >= 0 &&
    request.mass_nnz >= 0 &&
    request.jacobian_capacity >= 0 else {
    raise Unsupported::Invalid(
      "invalid or overflowing concrete physics dimensions",
    )
  }
  guard !request.kernels.is_empty() else {
    raise Unsupported::Invalid("at least one kernel required")
  }
  // These flags affect more than output layout. They cannot be approximated by
  // omitting the sleep/incremental/OBB branches.
  guard !request.enable_sleep &&
    !request.incremental &&
    request.filter_bits >= 0 &&
    request.filter_bits <= 7 else {
    raise Unsupported::Invalid(
      "sleep, incremental broadphase and OBB are not implemented",
    )
  }
  if request.kernels.contains("mass-multiply-sparse") {
    guard request.mass_nnz >= request.nv else {
      raise Unsupported::Invalid("sparse inertia must contain every diagonal")
    }
  }
  if request.kernels.contains("constraint-force-rebuild-sparse") {
    guard request.njmax > 0 &&
      request.jacobian_capacity > 0 &&
      request.nworld <= 2147483647 / request.njmax else {
      raise Unsupported::Invalid(
        "CSR constraint rows/capacity must be positive and fit launch indexing",
      )
    }
  }
  if request.kernels.contains("nxn-broadphase") {
    guard request.ngeom > 0 &&
      request.npair > 0 &&
      request.nworld <= 2147483647 / request.npair &&
      request.ngeom_aabb > 0 &&
      request.ngeom_rbound > 0 &&
      request.ngeom_margin > 0 &&
      request.ngeom_gap > 0 &&
      request.ngeom_dataid > 0 else {
      raise Unsupported::Invalid(
        "NXN requires positive candidate and model batch dimensions",
      )
    }
  }
}

///|
fn sparse_body(request : Request, key : String) -> String raise {
  match key {
    "mass-multiply-sparse" => {
      let gate = if request.check_skip {
        "if(wp::index(skip,i)) continue;\n"
      } else {
        ""
      }
      gate +
      (
        #|float acc=0.0f;
        #|int start=wp::index(M_mulm_rowadr,j),end=wp::index(M_mulm_rowadr,j+1);
        #|for(int k=start;k<end;k++) {
        #|  int col=wp::index(M_mulm_col,k),madr=wp::index(M_mulm_madr,k);
        #|  acc+=wp::index(M_in,i,madr)*wp::index(vec,i,col);
        #|}
        #|wp::index(res,i,j)=acc;
      )
    }
    "constraint-force-zero-sparse" =>
      (
        #|if(wp::index(ctx_done_in,i)) continue;
        #|if(wp::index(state_changed_count_in,i)==0) continue;
        #|wp::index(qfrc_constraint_out,i,j)=0.0f;
      )
    "constraint-force-rebuild-sparse" => {
      let compact = if request.compact {
        "col=wp::index(dof_cdof_in,i,col);if(col<0) continue;\n"
      } else {
        ""
      }
      let prefix =
        #|if(wp::index(ctx_done_in,i)) continue;
        #|if(wp::index(state_changed_count_in,i)==0) continue;
        #|if(j>=wp::index(nefc_in,i)) continue;
        #|float force=wp::index(efc_force_in,i,j);
        #|if(force==0.0f) continue;
        #|int rownnz=wp::index(efc_J_rownnz_in,i,j),rowadr=wp::index(efc_J_rowadr_in,i,j);
        #|for(int k=0;k<rownnz;k++) {
        #|  int sparseid=rowadr+k;
        #|  int col=wp::index(efc_J_colind_in,i,0,sparseid);
      let suffix =
        #|  float value=wp::index(efc_J_in,i,0,sparseid);
        #|  wp::atomic_add(qfrc_constraint_out,i,col,value*force);
        #|}
      prefix + "\n" + compact + suffix
    }
    _ => raise Unsupported::Invalid("unsupported sparse kernel body")
  }
}

///|
/// Actual typed lowerer for four independent source-specialized operations.
/// This does not generate a complete Newton/MuJoCo-Warp timestep.
pub fn lower(request : Request) -> Lowered raise {
  validate(request)
  let entries : Array[Entry] = []
  let seen : Map[String, Unit] = {}
  for key in request.kernels {
    guard !seen.contains(key) else {
      raise Unsupported::Invalid("duplicate physics kernel key")
    }
    seen[key] = ()
    entries.push(selected(request, key))
  }
  let blocks : Array[String] = [
    "// Concrete MuJoCo-Warp 3.15 kernel ports; Copyright 2025 The Newton Developers.\n// SPDX-License-Identifier: Apache-2.0\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56 && sizeof(bool)==1,\"Warp 1.17 64-bit ABI required\");\n",
  ]
  if request.kernels.contains("nxn-broadphase") {
    blocks.push(collision_helpers())
  }
  for e in entries {
    let signature = e.parameters.map(p => p.c_type + " " + p.name).join(", ")
    let operation = if e.key == "nxn-broadphase" {
      nxn_body(request)
    } else {
      sparse_body(request, e.key)
    }
    blocks.push(
      "extern \"C\" __global__ void " +
      e.forward +
      "(wp::launch_bounds_t<2> dim," +
      signature +
      "){\nfor(size_t linear=size_t(blockIdx.x)*blockDim.x+threadIdx.x;linear<dim.size;linear+=size_t(blockDim.x)*gridDim.x){\nauto coord=wp::launch_coord(linear,dim);int i=coord.i,j=coord.j;\n" +
      operation +
      "\n}\n}\n",
    )
  }
  let source = blocks.join("\n")
  let source_sha256 = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-mjw-concrete-physics-v1",
    "request": request.to_json(),
    "entries": entries.to_json(),
    "source_sha256": source_sha256.to_json(),
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
  }
  {
    source,
    source_sha256,
    specialization_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    request,
    entries,
  }
}
