///|
/// Explicit NVRTC compilation; source reading and lowering never initialize it.
pub async fn compile_specialization(config : CompileConfig) -> Json {
  let lowered = lower(config.request)
  guard !config.output.is_empty() && !@fs.exists(config.output) else {
    raise Unsupported::Invalid("fresh convex output directory required")
  }
  let kind = match config.kind {
    "ptx" => @compiler.ImageKind::Ptx
    "cubin" => @compiler.ImageKind::Cubin
    _ => raise Unsupported::Invalid("kind must be ptx or cubin")
  }
  let options = compile_options(config.options, config.kind)
  let root = @fs.realpath(config.mujoco_warp_root) + "/mujoco_warp/_src/"
  let native = @fs.realpath(config.warp_native)
  let nvrtc = @fs.realpath(config.nvrtc_library)
  let files = [
    "collision_gjk.py", "collision_convex.py", "collision_core.py", "types.py",
  ]
  let sources : Map[String, Bytes] = {}
  let evidence : Array[Json] = []
  let definitions : Array[Json] = []
  for file in files {
    let bytes = @fs.read_file(root + file).binary()
    let sha = @artifacts.sha256(bytes)
    guard sha == source_sha(file) else {
      raise Unsupported::Invalid(
        "MuJoCo-Warp 3.15 convex source differs: " + file,
      )
    }
    sources[file] = bytes
    evidence.push({
      "file": file.to_json(),
      "sha256": sha.to_json(),
      "snapshot": ("upstream/" + file + ".source").to_json(),
    })
    let text = @utf8.decode(bytes)
    for name in definitions_for(file) {
      definitions.push({
        "file": file.to_json(),
        "function": name.to_json(),
        "definition_sha256": @artifacts.sha256(
          @utf8.encode(definition(text, name)),
        ).to_json(),
      })
    }
  }
  let paths = []
  header_paths(native, "", paths)
  let headers : Array[@compiler.Header] = []
  let header_bytes : Map[String, Bytes] = {}
  let header_inventory : Array[Json] = []
  let mut total = 0
  for name in paths {
    let bytes = @fs.read_file(native + "/" + name).binary()
    guard bytes.length() <= 33554432 && total <= 134217728 - bytes.length() else {
      raise Unsupported::Invalid("native header inventory too large")
    }
    total += bytes.length()
    headers.push({ include_name: name, source: @utf8.decode(bytes), })
    header_bytes[name] = bytes
    header_inventory.push({
      "include_name": name.to_json(),
      "path": ("headers/" + name).to_json(),
      "sha256": @artifacts.sha256(bytes).to_json(),
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
    guard header_bytes.get(name) is Some(bytes) &&
      @artifacts.sha256(bytes) == sha else {
      raise Unsupported::Invalid(
        "genuine Warp 1.17 ABI header differs: " + name,
      )
    }
  }
  let compiler_sha = @artifacts.sha256(@fs.read_file(nvrtc).binary())
  let compiler = @compiler.Compiler::open(nvrtc)
  let compiled = compiler.compile({
    source: lowered.source,
    program_name: "moonrobo-native-convex-gjk.cu",
    headers,
    options,
    kind,
  })
  let image = "module." + config.kind
  let manifest : Json = {
    "format": "moonrobo-native-convex-gjk-module-v1",
    "producer": "moonbit-typed-mujoco-warp-convex-gjk-subset",
    "mujoco_warp_version": "3.15.0",
    "warp_version": "1.17.0",
    "request": config.request.to_json(),
    "entry": lowered.entry.to_json(),
    "source": { "path": "gjk.cu", "sha256": lowered.source_sha256.to_json() },
    "specialization_sha256": lowered.specialization_sha256.to_json(),
    "upstream_files": evidence.to_json(),
    "upstream_definitions": definitions.to_json(),
    "definition_evidence_is_not_full_symbol_coverage_claim": true,
    "headers": header_inventory.to_json(),
    "abi_headers_attested": ["array.h", "builtin.h"],
    "other_header_bytes_observed_and_snapshotted": true,
    "external_include_bytes_attested": false,
    "compiler": {
      "path": nvrtc.to_json(),
      "sha256": compiler_sha.to_json(),
      "version": compiled.version.to_json(),
      "options": options.to_json(),
      "transitive_native_dependencies_attested": false,
    },
    "image": {
      "path": image.to_json(),
      "kind": config.kind.to_json(),
      "sha256": @artifacts.sha256(compiled.image).to_json(),
    },
    "log": {
      "path": "compile.log",
      "sha256": @artifacts.sha256(@utf8.encode(compiled.log)).to_json(),
    },
    "launch_policy": {
      "block_dim": 256,
      "forward_smem": 0,
      "backward_smem": 0,
      "grid_stride": true,
      "coord_mult": 1,
    },
    "launch_abi": "warp-1.17-64bit-launch-bounds-array-by-value",
    "mesh_support_algorithm": "graphadr=-1-exhaustive-local-vertex-search-with-cache-ties",
    "mesh_pointer_required": false,
    "cooked_convex_hull_or_graph_created": false,
    "distance_semantics": "margin-inflated-gjk-phase-distance; final-ccd-contact-distance-requires-plus-candidate-margin",
    "witness_semantics": "world-coordinates-on-margin-inflated-geometries; cutoff-status-has-no-witness",
    "separated_flag_semantics": "last-core-GJK-geometry; shallow-stage-may-have-shrunken-sphere-or-capsule",
    "candidate_margin_semantics": "same-actual-resolved-pair-margin-assigned-to-both-geoms-as-upstream-ccd-kernel",
    "status_codes": {
      "inactive": 0,
      "distance": 1,
      "cutoff_lower_bound_no_witness": 2,
      "shallow_inflated": 3,
      "epa_required": 10,
      "iteration_limit": 11,
      "invalid_candidate_or_descriptor": 12,
      "numeric_or_degenerate": 13,
      "unsupported_geom": 14,
    },
    "rejected_counters": [
      "epa_required", "iteration_limit", "invalid_candidate_or_descriptor", "numeric_or_degenerate",
      "unsupported_geom",
    ],
    "mandatory_host_view_validation": "validate_bindings(request, actual_owned_buffer_views)",
    "mandatory_completed_readback_gate": "validate_results(request, actual_candidate_count, actual_status, actual_rejected)",
    "require_rejected_counters_zero_before_publish": true,
    "native_descriptor_shape_gates_generated": true,
    "iteration_exhaustion_is_failure": true,
    "unsupported_pair_fallback": false,
    "core_gjk_and_simplex_computation_generated": true,
    "shallow_sphere_capsule_inflation_generated": true,
    "epa_generated": false,
    "multicontact_manifold_generated": false,
    "final_material_contact_writer_generated": false,
    "full_narrowphase_closure": false,
    "full_collision_closure": false,
    "full_solver_closure": false,
    "complete_timestep_generated": false,
    "generated_adjoint": false,
    "warp_meta_generated": false,
    "runtime_equivalence_verified": false,
  }
  @fs.mkdir(config.output, recursive=true)
  let folder = config.output + "/"
  @fs.write_file(folder + "gjk.cu", lowered.source, create_mode=CreateNew)
  @fs.write_file(folder + image, compiled.image, create_mode=CreateNew)
  @fs.write_file(folder + "compile.log", compiled.log, create_mode=CreateNew)
  for name in paths {
    write_nested(folder + "headers/", name, header_bytes[name])
  }
  for file in files {
    write_nested(folder + "upstream/", file + ".source", sources[file])
  }
  @fs.write_file(
    folder + "manifest.json",
    manifest.stringify(indent=2),
    create_mode=CreateNew,
  )
  manifest
}
