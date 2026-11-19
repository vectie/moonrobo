///|
fn contract_manifest() -> Manifest {
  let widths : Array[(String, Int32)] = [
    ("root_pose", 7),
    ("root_com_velocity", 6),
    ("root_com_local", 3),
    ("joint_position", 29),
    ("joint_velocity", 29),
    ("targets", 29),
    ("reset_pose", 7),
    ("reset_velocity", 6),
    ("reset_joint_position", 29),
    ("reset_joint_velocity", 29),
    ("reset_mask", 1),
  ]
  let views : Map[String, BufferView] = {}
  let shared_regions = []
  for (name, width) in widths {
    let scalar = if name == "reset_mask" { 1 } else { 4 }
    views[name] = {
      binding: name,
      offset_elements: 0,
      row_stride_elements: width,
      component_stride_elements: 1,
      width,
    }
    shared_regions.push({
      name,
      bytes: 2 * width * scalar,
      scalar_type: if scalar == 1 {
        "bool"
      } else {
        "float32"
      },
    })
  }
  shared_regions.push({ name: "shape_mu", bytes: 24, scalar_type: "float32", })
  shared_regions.push({ name: "body_com", bytes: 24, scalar_type: "float32", })
  {
    format: "moonrobo.aligned-apic-bundle.v1",
    versions: {
      warp: "1.17.0",
      isaaclab_revision: "46d6cc3d7b115906fad12efd372fbf69f4e3d3ed",
      newton_revision: "71eeba16a717d4dcf0b9dd7056a7b6f863054dc3",
      mujoco_warp: "3.15.0",
    },
    num_envs: 2,
    capacity_profile: None,
    asset: {
      usd_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      mjcf_sha256: "source-model",
    },
    usd_variants: {},
    self_collisions: true,
    control_dt_s: 0.02,
    physics_dt_s: 0.005,
    num_substeps: 4,
    joint_names: @aligned.joint_names(),
    graphs: {
      step: "step.wrp",
      reset: "reset.wrp",
      context: "context.wrp",
      refresh: "refresh.wrp",
    },
    files: ["step.wrp", "reset.wrp", "context.wrp", "refresh.wrp"].map(path => {
      path,
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    }),
    shared_regions,
    views,
    context_writes: {
      shape_friction: { binding: "shape_mu", indices: [[0, 1], [2, 3]], },
      ground_friction: { binding: "shape_mu", indices: [4, 5], },
      torso_com: {
        binding: "body_com",
        indices: [[0, 1, 2], [3, 4, 5]],
        base: [[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]],
      },
    },
    env_origins: [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
    capture_contract: {
      physics_steps_per_control: 4,
      uses_single_state: true,
      uncaptured_manager_simulate_full: true,
      includes_actuator_adapter: true,
      step_method: None,
      all_implicit_capture: None,
      context_model_change_flags: [
        "SHAPE_PROPERTIES", "BODY_INERTIAL_PROPERTIES",
      ],
      reset_clears_solver_warm_start: true,
      persistent_numeric_union_complete: true,
      update_data_interval: 1,
      broadphase: "NXN",
    },
    solver_cfg: {
      njmax: 500,
      nconmax: 128,
      integrator: "implicitfast",
      cone: "pyramidal",
      use_mujoco_contacts: true,
    },
  }
}

///|
fn implicit_contract() -> CaptureContract {
  {
    ..contract_manifest().capture_contract,
    step_method: Some("_simulate_physics_only"),
    uncaptured_manager_simulate_full: false,
    includes_actuator_adapter: false,
    all_implicit_capture: Some({
      joint_count: 29,
      group_count: 29,
      all_groups_exact_implicit: true,
      each_group_single_joint: true,
      fixed_tendon_count: 0,
      execution_actuator_count: 0,
      native_group_count: 0,
      implicit_executor_present: true,
      implicit_executor_group_count: 29,
      native_actuator_path_active: false,
      manager_native_actuator_path_active: false,
      adapter_present: false,
      pre_actuator_callback_count: 0,
      post_actuator_callback_count: 0,
      // User-order refresh callbacks are valid and remain inside the SDK step.
      post_step_callback_count: 1,
      post_step_callbacks_preserved: true,
      scene_write_data_to_sim_included: true,
      command_submission: None,
    }),
  }
}

///|
fn implicit_kernel_commands() -> ImplicitCommandCapture {
  {
    method: "pinned_implicit_target_kernel",
    target_kernel: "isaaclab.assets.articulation.ordering_kernels.launch_reorder_joint_targets_user_to_backend",
    uses_actual_joint_map: true,
    compute_processed_targets: true,
    writes_effort_position_velocity: true,
    writes_native_joint_act: false,
    coordinate_scatter_preserved: true,
    external_wrench_logic_preserved: true,
    dirty_tendon_submission_preserved: true,
    other_scene_writers_preserved: true,
  }
}

///|
test "implicit target kernel accepts only a complete recorded SDK composition" {
  let source = contract_manifest()
  let c = implicit_contract()
  let p = c.all_implicit_capture.unwrap()
  let commands = implicit_kernel_commands()
  let proof = {
    ..p,
    scene_write_data_to_sim_included: false,
    command_submission: Some(commands),
  }
  let manifest = {
    ..source,
    capture_contract: { ..c, all_implicit_capture: Some(proof), },
  }
  let decoded : Manifest = @json.from_json(Json(manifest))
  decoded.validate("source-model", true)
  for
    changed in [
      { ..commands, method: "custom_solver", },
      { ..commands, target_kernel: "wp.copy", },
      { ..commands, uses_actual_joint_map: false, },
      { ..commands, compute_processed_targets: false, },
      { ..commands, writes_effort_position_velocity: false, },
      { ..commands, writes_native_joint_act: true, },
      { ..commands, coordinate_scatter_preserved: false, },
      { ..commands, external_wrench_logic_preserved: false, },
      { ..commands, dirty_tendon_submission_preserved: false, },
      { ..commands, other_scene_writers_preserved: false, },
    ] {
    let rejected = try {
      { ..proof, command_submission: Some(changed), }.validate_commands()
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  for
    changed in [
      { ..proof, scene_write_data_to_sim_included: true, },
      { ..proof, command_submission: None, },
    ] {
    let rejected = try {
      changed.validate_commands()
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "plain implicit APIC step roundtrips and retains post-step callbacks" {
  let source = contract_manifest()
  let manifest = { ..source, capture_contract: implicit_contract(), }
  let decoded : Manifest = @json.from_json(Json(manifest))
  decoded.validate("source-model", true)
  assert_eq(
    decoded.capture_contract.step_method,
    Some("_simulate_physics_only"),
  )
  assert_true(!decoded.capture_contract.includes_actuator_adapter)
  let proof = decoded.capture_contract.all_implicit_capture.unwrap()
  assert_eq(proof.post_step_callback_count, 1)
  assert_true(proof.post_step_callbacks_preserved)
}

///|
test "legacy full APIC contract permits missing optional branch fields" {
  // Older genuine full captures predate the branch fields. Missing fields
  // must decode as None; absence never authorizes a physics-only capture.
  let legacy : Json = {
    "physics_steps_per_control": 4,
    "uses_single_state": true,
    "uncaptured_manager_simulate_full": true,
    "includes_actuator_adapter": true,
    "context_model_change_flags": [
      "SHAPE_PROPERTIES", "BODY_INERTIAL_PROPERTIES",
    ],
    "reset_clears_solver_warm_start": true,
    "persistent_numeric_union_complete": true,
    "update_data_interval": 1,
    "broadphase": "NXN",
  }
  let decoded : CaptureContract = @json.from_json(legacy)
  assert_eq(decoded.step_method, None)
  assert_true(decoded.all_implicit_capture is None)
  let source = contract_manifest()
  { ..source, capture_contract: decoded, }.validate("source-model", true)
}

///|
test "APIC physics-only path rejects unproved or contradictory step claims" {
  let source = contract_manifest()
  let implicit = implicit_contract()
  for
    changed in [
      { ..implicit, step_method: None, },
      { ..implicit, step_method: Some("_simulate_full"), },
      { ..implicit, step_method: Some("replacement_solver"), },
      { ..implicit, all_implicit_capture: None, },
      { ..implicit, uncaptured_manager_simulate_full: true, },
      { ..implicit, includes_actuator_adapter: true, },
    ] {
    let rejected = try {
      { ..source, capture_contract: changed, }.validate("source-model", true)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "APIC implicit proof rejects skipped execution and lost callbacks" {
  let source = contract_manifest()
  let implicit = implicit_contract()
  let p = implicit.all_implicit_capture.unwrap()
  for
    changed in [
      { ..p, joint_count: 28, },
      { ..p, group_count: 28, },
      { ..p, all_groups_exact_implicit: false, },
      { ..p, each_group_single_joint: false, },
      { ..p, fixed_tendon_count: 1, },
      { ..p, execution_actuator_count: 1, },
      { ..p, native_group_count: 1, },
      { ..p, implicit_executor_present: false, },
      { ..p, implicit_executor_group_count: 28, },
      { ..p, native_actuator_path_active: true, },
      { ..p, manager_native_actuator_path_active: true, },
      { ..p, adapter_present: true, },
      { ..p, pre_actuator_callback_count: 1, },
      { ..p, post_actuator_callback_count: 1, },
      { ..p, post_step_callback_count: -1, },
      { ..p, post_step_callbacks_preserved: false, },
      { ..p, scene_write_data_to_sim_included: false, },
    ] {
    let rejected = try {
      {
        ..source,
        capture_contract: { ..implicit, all_implicit_capture: Some(changed), },
      }.validate("source-model", true)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "pinned complete APIC manifest contract and solver configuration" {
  let source = contract_manifest()
  source.validate("source-model", true)
  for
    solver in [
      { ..source.solver_cfg, integrator: "Euler", },
      { ..source.solver_cfg, cone: "elliptic", },
      { ..source.solver_cfg, njmax: 100, },
      { ..source.solver_cfg, nconmax: 64, },
      { ..source.solver_cfg, use_mujoco_contacts: false, },
    ] {
    let rejected = try {
      { ..source, solver_cfg: solver, }.validate("source-model", true)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "APIC artifact rejects model timing SDK and incomplete cache update" {
  let source = contract_manifest()
  for
    changed in [
      { ..source, physics_dt_s: 0.002, },
      { ..source, num_substeps: 1, },
      { ..source, versions: { ..source.versions, warp: "1.18.0", }, },
      {
        ..source,
        capture_contract: {
          ..source.capture_contract,
          context_model_change_flags: ["SHAPE_PROPERTIES"],
        },
      },
      {
        ..source,
        capture_contract: {
          ..source.capture_contract,
          includes_actuator_adapter: false,
        },
      },
      {
        ..source,
        capture_contract: {
          ..source.capture_contract,
          update_data_interval: 2,
        },
      },
    ] {
    let rejected = try {
      changed.validate("source-model", true)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "APIC views reject span overflow aliasing and overlapping context indices" {
  for changed in 0..<3 {
    let source = contract_manifest()
    let view = source.views.get_or_default("reset_pose", {
      binding: "",
      offset_elements: 0,
      row_stride_elements: 0,
      component_stride_elements: 1,
      width: 7,
    })
    if changed == 0 {
      source.views["reset_pose"] = {
        ..view,
        offset_elements: 2147483647,
        row_stride_elements: 2147483647,
        component_stride_elements: 2147483647,
      }
    } else if changed == 1 {
      source.views["reset_pose"] = { ..view, binding: "root_pose", }
    } else {
      source.context_writes.ground_friction.indices[0] = 0
    }
    let rejected = try {
      source.validate("source-model", true)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_true(!relative_path("../outside.cubin"))
  assert_true(!relative_path("/outside.cubin"))
  assert_true(!relative_path("x/../outside.cubin"))
}
