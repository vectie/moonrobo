///|
/// Read/validate source receipts without calling a compiler or CUDA API.
async fn read_module(input : ModuleInput, architecture : Int32) -> Module {
  guard identifier(input.id) && @contracts.sha256_hex(input.manifest_sha256) else {
    fail("invalid GPU module identity")
  }
  let root = @fs.realpath(input.directory)
  let manifest = @fs.read_file(root + "/manifest.json").binary()
  guard @artifacts.sha256(manifest) == input.manifest_sha256 else {
    fail("GPU module manifest SHA differs")
  }
  let json = @json.parse(@utf8.decode(manifest))
  let kind = text(json, "format")
  let request = field(json, "request")
  let entries : Map[String, Entry] = {}
  let expected_policy : Ref[LaunchPolicy] = Ref({
    block_dim: 256,
    forward_smem: 0,
    backward_smem: 0,
    grid_stride: true,
    coord_mult: 1,
  })
  let (source_name, source_sha, specialization) = match kind {
    "moonrobo-g1-concrete-kernel-module-v1" => {
      let typed : @kernels.SpecializationRequest = @json.from_json(request)
      ignore(
        fields(request, ["num_envs", "num_joints", "num_bodies", "kernels"]),
      )
      let lower = @kernels.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("G1 module typed entry metadata differs")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      (
        text(json, "source_path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-mjw-concrete-physics-module-v1" => {
      let typed : @physics_kernels.Request = @json.from_json(request)
      ignore(
        fields(request, [
          "nworld", "nv", "ngeom", "npair", "njmax", "mass_nnz", "jacobian_capacity",
          "filter_bits", "ngeom_aabb", "ngeom_rbound", "ngeom_margin", "ngeom_gap",
          "ngeom_dataid", "check_skip", "compact", "enable_sleep", "incremental",
          "kernels",
        ]),
      )
      let lower = @physics_kernels.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("physics module typed entry metadata differs")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-primitive-contact-module-v1" => {
      let typed : @narrowphase.Request = @json.from_json(request)
      ignore(
        fields(request, [
          "nworld", "ngeom", "candidate_capacity", "contact_capacity", "efc_slots",
          "pairs",
        ]),
      )
      let lower = @narrowphase.lower(typed)
      guard field(json, "entry") == lower.entry.to_json() else {
        fail("narrowphase typed entry metadata differs")
      }
      entries["contacts"] = {
        key: "contacts",
        forward: lower.entry.forward,
        shape: lower.entry.launch_shape,
        parameters: @json.from_json(lower.entry.parameters.to_json()),
      }
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-device-convergence-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "nv", "iterations", "warn_overflow", "kernels",
        ]),
      )
      let typed : @device_convergence.Request = @json.from_json(request)
      let lower = @device_convergence.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("device convergence entry metadata differs")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-convex-gjk-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "ngeom", "candidate_capacity", "vertex_capacity", "gjk_iterations",
          "tolerance", "cutoff",
        ]),
      )
      let typed : @convex.Request = @json.from_json(request)
      let lower = @convex.lower(typed)
      guard field(json, "entry") == lower.entry.to_json() else {
        fail("convex GJK entry metadata differs")
      }
      entries["convex-gjk"] = {
        key: "convex-gjk",
        forward: lower.entry.forward,
        shape: lower.entry.launch_shape,
        parameters: @json.from_json(lower.entry.parameters.to_json()),
      }
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-mathdx-tile-module-v1" => {
      ignore(
        fields(request, [
          "operation", "dtype", "tile_size", "rhs_columns", "batch_size", "block_dim",
          "architecture",
        ]),
      )
      let typed : @tile_solver.Request = @json.from_json(request)
      guard typed.architecture == architecture else {
        fail(
          "MathDx linked CUBIN target differs from explicit device architecture",
        )
      }
      let lower = @tile_solver.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("MathDx tile entry metadata differs")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(json, "source_path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-convex-contact-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "ngeom", "candidate_capacity", "contact_capacity", "vertex_capacity",
          "polygon_capacity", "polygon_vertex_capacity", "polygon_map_capacity",
          "graph_capacity", "efc_slots", "gjk_iterations", "epa_iterations", "hfield_capacity",
          "hfield_data_capacity", "epa_vertices", "epa_faces", "epa_horizon", "max_polygon_vertices",
          "tolerance", "use_multiccd",
        ]),
      )
      let typed : @convex_contacts.Request = @json.from_json(request)
      let lower = @convex_contacts.lower(typed)
      guard field(json, "entry") == lower.entry.to_json() else {
        fail("convex contact entry metadata differs")
      }
      entries["convex-contacts"] = {
        key: "convex-contacts",
        forward: lower.entry.forward,
        shape: lower.entry.launch_shape,
        parameters: @json.from_json(lower.entry.parameters.to_json()),
      }
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-mixed-sparse-solver-module-v1" => {
      ignore(
        fields(request, [
          "layout", "dtype", "nworld", "block_dim", "architecture", "check_done",
        ]),
      )
      let typed : @sparse_solver.Request = @json.from_json(request)
      guard typed.architecture == architecture else {
        fail("mixed sparse solver architecture differs")
      }
      let lower = @sparse_solver.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("mixed sparse solver typed entries differ")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-sparse-lu-module-v1" => {
      ignore(
        fields(request, [
          "layout", "dtype", "nworld", "block_dim", "architecture", "check_done",
        ]),
      )
      let typed : @sparse_solver.LuRequest = @json.from_json(request)
      guard typed.architecture == architecture else {
        fail("sparse LU architecture differs")
      }
      let lower = @sparse_solver.lower_lu(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("sparse LU typed entries differ")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-newton-solver-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "nv", "njmax", "ncon", "mass_nnz", "jacobian_capacity", "iterations",
          "ls_iterations", "solver", "jacobian_layout", "mass_layout", "cone", "warmstart",
          "kernels",
        ]),
      )
      let typed : @newton_solver.Request = @json.from_json(request)
      let lower = @newton_solver.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("Newton solver typed entries differ")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-solver-metrics-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "nv", "nC", "nK", "nblock", "nefm0", "nefm0L", "ntendon", "tendon_nnz",
          "nactuator", "moment_nnz", "njmax", "jacobian_nnz", "ncon", "contact_width",
          "ntree", "sparse_jacobian", "sleep", "check_skip", "architecture", "kernels",
        ]),
      )
      let typed : @solver_metrics.Request = @json.from_json(request)
      guard typed.architecture == architecture else {
        fail("effective metric helper architecture differs")
      }
      let lower = @solver_metrics.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("effective metric helper typed entries differ")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    "moonrobo-native-solver-adapters-module-v1" => {
      ignore(
        fields(request, [
          "nworld", "nv", "nv_compact", "njmax", "mass_nnz", "jacobian_capacity",
          "gather_nnz", "jacobian_layout", "compact", "stable_fast", "kernels",
        ]),
      )
      let typed : @solver_adapters.Request = @json.from_json(request)
      let lower = @solver_adapters.lower(typed)
      guard field(json, "entries") == lower.entries.to_json() else {
        fail("solver adapter typed entries differ")
      }
      for item in lower.entries {
        entries[item.key] = {
          key: item.key,
          forward: item.forward,
          shape: item.launch_shape,
          parameters: @json.from_json(item.parameters.to_json()),
        }
      }
      expected_policy.val = @json.from_json(lower.launch_policy.to_json())
      (
        text(field(json, "source"), "path"),
        lower.source_sha256,
        lower.specialization_sha256,
      )
    }
    _ =>
      fail(
        "GPU pipeline accepts only supported concrete first-party lowerer receipts",
      )
  }
  guard @contracts.relative_path(source_name) &&
    text(json, "specialization_sha256") == specialization &&
    text(json, "warp_version") == "1.17.0" &&
    text(json, "launch_abi") == "warp-1.17-64bit-launch-bounds-array-by-value" &&
    field(json, "generated_adjoint") == Json(false) else {
    fail("GPU module specialization/ABI/version differs")
  }
  let observed_source = if kind == "moonrobo-g1-concrete-kernel-module-v1" ||
    kind == "moonrobo-mathdx-tile-module-v1" {
    text(json, "source_sha256")
  } else {
    text(field(json, "source"), "sha256")
  }
  let source = @fs.read_file(root + "/" + source_name).binary()
  guard observed_source == source_sha && @artifacts.sha256(source) == source_sha else {
    fail("GPU module source SHA differs from recomputed lowerer")
  }
  let policy_json = field(json, "launch_policy")
  ignore(
    fields(policy_json, [
      "block_dim", "forward_smem", "backward_smem", "grid_stride", "coord_mult",
    ]),
  )
  let policy : LaunchPolicy = @json.from_json(policy_json)
  guard policy.to_json() == expected_policy.val.to_json() else {
    fail("unsupported generated launch policy; no ABI guess/fallback")
  }
  let image_info = field(json, "image")
  let image_kind = text(image_info, "kind")
  let image_name = text(image_info, "path")
  let image_sha256 = text(image_info, "sha256")
  guard (image_kind == "ptx" || image_kind == "cubin") &&
    image_name == "module." + image_kind &&
    @contracts.sha256_hex(image_sha256) else {
    fail("GPU module image kind/path/hash is invalid")
  }
  let image = @fs.read_file(root + "/" + image_name).binary()
  guard !image.is_empty() && @artifacts.sha256(image) == image_sha256 else {
    fail("GPU module actual image SHA differs")
  }
  if kind == "moonrobo-mathdx-tile-module-v1" {
    let compiler = field(json, "compiler")
    guard image_kind == "cubin" &&
      text(compiler, "api") == "wp_cuda_compile_solver+wp_cuda_compile_program" &&
      field(compiler, "optimization_level") == Json(3) &&
      field(compiler, "debug") == Json(false) &&
      field(compiler, "fast_math") == Json(false) &&
      field(compiler, "fuse_fp") == Json(false) &&
      field(compiler, "precompiled_headers") == Json(false) else {
      fail("MathDx CUBIN compiler policy differs")
    }
  } else {
    let options : Array[String] = @json.from_json(
      field(field(json, "compiler"), "options"),
    )
    let target = (if image_kind == "ptx" { "compute_" } else { "sm_" }) +
      architecture.to_string()
    let flags = options.filter(option => {
      option.has_prefix("--gpu-architecture=") || option.has_prefix("-arch=")
    })
    guard flags.length() == 1 &&
      (
        flags[0] == "--gpu-architecture=" + target ||
        flags[0] == "-arch=" + target
      ) else {
      fail("GPU image architecture differs from explicit device target")
    }
  }
  let notice = if @fs.exists(root + "/NOTICE") {
    Some(@fs.read_file(root + "/NOTICE").binary())
  } else {
    None
  }
  guard kind != "moonrobo-g1-concrete-kernel-module-v1" ||
    (notice is Some(bytes) && !bytes.is_empty()) else {
    fail("G1 generated artifact requires its genuine NOTICE")
  }
  {
    id: input.id,
    kind,
    request,
    manifest,
    manifest_sha256: input.manifest_sha256,
    source,
    source_name,
    source_sha256: source_sha,
    image,
    image_kind,
    image_sha256,
    specialization_sha256: specialization,
    entries,
    policy,
    notice,
  }
}
