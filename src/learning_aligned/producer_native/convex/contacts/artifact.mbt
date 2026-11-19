///|
/// Explicit future NVRTC compile. Source reading and MoonBit checks never call
/// this operation, initialize CUDA or claim a successful contact computation.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    raise Unsupported::Invalid("fresh convex-contact output required")
  }
  let kind = match config.kind {
    "ptx" => @compiler.ImageKind::Ptx
    "cubin" => @compiler.ImageKind::Cubin
    _ => raise Unsupported::Invalid("kind must be ptx or cubin")
  }
  let options = compile_options(config.options, config.kind)
  let source_root = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let native = @fs.realpath(config.warp_native)
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let sources : Map[String, Bytes] = {}
  let source_inventory : Array[Json] = []
  let definitions : Array[Json] = []
  for
    file in [
      "collision_gjk.py", "collision_convex.py", "collision_core.py", "collision_primitive.py",
      "collision_primitive_core.py", "math.py", "types.py",
    ] {
    let bytes = @fs.read_file(source_root + file).binary()
    guard @artifacts.sha256(bytes) == source_sha(file) else {
      raise Unsupported::Invalid(
        "fixed MuJoCo-Warp 3.15 source differs: " + file,
      )
    }
    sources[file] = bytes
    source_inventory.push({
      "file": Json(file),
      "sha256": Json(source_sha(file)),
      "path": Json("upstream/" + file + ".source"),
    })
    let source = @utf8.decode(bytes)
    for name in definition_names(source) {
      definitions.push({
        "file": Json(file),
        "function": Json(name),
        "definition_sha256": Json(
          @artifacts.sha256(@utf8.encode(definition(source, name))),
        ),
      })
    }
  }
  let paths = []
  header_paths(native, "", paths)
  let headers : Array[@compiler.Header] = []
  let bytes_by_name : Map[String, Bytes] = {}
  let header_inventory : Array[Json] = []
  let mut total = 0
  for name in paths {
    let bytes = @fs.read_file(native + "/" + name).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise Unsupported::Invalid("native header inventory exceeds capacity")
    }
    total += bytes.length()
    bytes_by_name[name] = bytes
    headers.push({ include_name: name, source: @utf8.decode(bytes), })
    header_inventory.push({
      "include_name": Json(name),
      "path": Json("headers/" + name),
      "sha256": Json(@artifacts.sha256(bytes)),
    })
  }
  for
    (name, sha) in [
      (
        "builtin.h", "9a8c44dda8453dcee2308ec016a648da43bc77d41427c7694b6555a1f810d7bf",
      ),
      (
        "array.h", "f85ab644afcf70be5b9feb6097fd9ffe4dfe22d5f88948c511609dac60b2d07a",
      ),
    ] {
    guard bytes_by_name.get(name) is Some(bytes) &&
      @artifacts.sha256(bytes) == sha else {
      raise Unsupported::Invalid("Warp 1.17 ABI header differs: " + name)
    }
  }
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let backend = @compiler.Compiler::open(nvrtc)
  let compiled = backend.compile({
    source: lowered.source,
    program_name: "moonrobo-native-convex-contacts.cu",
    headers,
    options,
    kind,
  })
  guard @artifacts.sha256(@fs.read_file(nvrtc).binary()) == compiler_sha else {
    raise Unsupported::Invalid("NVRTC root library changed during compilation")
  }
  let image = "module." + config.kind
  let manifest : Json = {
    "format": "moonrobo-native-convex-contact-module-v1",
    "producer": "moonbit-typed-mujoco-warp-convex-contacts",
    "request": Json(config.request),
    "entry": Json(lowered.entry),
    "source": { "path": "contacts.cu", "sha256": Json(lowered.source_sha256) },
    "specialization_sha256": Json(lowered.specialization_sha256),
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
    "upstream_files": Json(source_inventory),
    "upstream_definitions": Json(definitions),
    "definition_evidence_is_not_full_symbol_coverage_claim": true,
    "bound_source_constants": {
      "mjMAXCONPAIR": 50,
      "mjMAXVAL": 1.0e10,
      "primary_header_version": "MuJoCo 3.3.7",
      "primary_header_path": "include/mujoco/mjmodel.h",
      "primary_header_sha256": "9462092aa6d958d54d7d20edfb85f2c16585e712fea15ed4c1593c5cb430522a",
      "runtime_query_performed": false,
    },
    "headers": Json(header_inventory),
    "abi_headers_attested": ["array.h", "builtin.h"],
    "other_header_bytes_observed_and_snapshotted": true,
    "external_include_bytes_attested": false,
    "compiler": {
      "path": Json(nvrtc),
      "sha256": Json(compiler_sha),
      "version": Json(compiled.version),
      "options": Json(options),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "path": Json(image),
      "kind": Json(config.kind),
      "sha256": Json(@artifacts.sha256(compiled.image)),
    },
    "log": {
      "path": "compile.log",
      "sha256": Json(@artifacts.sha256(@utf8.encode(compiled.log))),
    },
    "launch_policy": {
      "block_dim": 256,
      "forward_smem": 0,
      "backward_smem": 0,
      "grid_stride": true,
      "coord_mult": 1,
    },
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "typed_array_count": 69,
    "scratch_layout": "six explicit owned rank2 arrays, disjoint candidate rows; manifold bounded local arrays",
    "contact_distance_semantics": "upstream inflated CCD dist gate, then plus resolved margin; manifold per-slot distances preserved",
    "rejected_counters": [
      "unsupported_geom", "invalid_descriptor_index_or_contact_overflow", "gjk_failure",
      "epa_vertex_face_capacity", "epa_horizon_capacity", "epa_failure", "manifold_topology_capacity",
      "nonfinite_export",
    ],
    "mandatory_host_view_validation": "validate_bindings(request,actual_owned_buffer_views)",
    "mandatory_completed_readback_gate": "validate_results(request,actual_candidate_count,actual_contact_count,actual_rejected)",
    "require_rejected_counters_zero_before_publish": true,
    "initial_nacon_nonnegative_and_within_capacity_required": true,
    "counter_owners_must_be_protected_from_other_writers": true,
    "initial_snapshots_before_capture_required": true,
    "primitive_mesh_support_generated": true,
    "epa_generated": true,
    "multicontact_manifold_generated": true,
    "final_material_contact_writer_generated": true,
    "plane_primitive_and_mesh_contacts_generated": true,
    "heightfield_prism_dispatch_generated": true,
    "flex_triangle_support_helpers_generated": true,
    "flex_triangle_dispatch_generated": false,
    "mesh_hillclimb_support_generated": true,
    "upstream_dynamic_workqueue_and_occupancy_generated": false,
    "full_collision_closure": false,
    "full_solver_closure": false,
    "complete_timestep_generated": false,
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  @fs.write_file(
    config.output + "/contacts.cu",
    lowered.source,
    create_mode=CreateNew,
  )
  @fs.write_file(
    config.output + "/" + image,
    compiled.image,
    create_mode=CreateNew,
  )
  @fs.write_file(
    config.output + "/compile.log",
    compiled.log,
    create_mode=CreateNew,
  )
  for name in paths {
    write_nested(config.output, "headers/" + name, bytes_by_name[name])
  }
  for file, bytes in sources {
    write_nested(config.output, "upstream/" + file + ".source", bytes)
  }
  @fs.write_file(
    config.output + "/manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
