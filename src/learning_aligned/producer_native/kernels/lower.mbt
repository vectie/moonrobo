///|
fn entry(request : SpecializationRequest, key : String) -> Entry raise {
  let matrix = [request.num_envs, request.num_joints]
  let (forward, path, function, shape, parameters) = match key {
    "root-pose-mask" =>
      (
        "mr_g1_root_pose_mask",
        shared_path(),
        "set_root_link_pose_to_sim_mask",
        [request.num_envs],
        [
          array("data", "transformf", 1, "input"),
          array("env_mask", "bool", 1, "input"),
          array("root_link_pose_w", "transformf", 1, "output"),
        ],
      )
    "root-velocity-mask" =>
      (
        "mr_g1_root_velocity_mask",
        shared_path(),
        "set_root_com_velocity_to_sim_mask",
        [request.num_envs],
        [
          array("data", "spatial_vectorf", 1, "input"),
          array("env_mask", "bool", 1, "input"),
          integer("num_bodies"),
          array("root_com_velocity_w", "spatial_vectorf", 1, "output"),
          array("body_acc_w", "spatial_vectorf", 2, "output"),
        ],
      )
    "joint-position-mask" =>
      (
        "mr_g1_joint_position_mask",
        ordering_path(),
        "_write_2d_user_to_backend_with_mask",
        matrix,
        [
          array("input_data", "float32", 2, "input"),
          array("env_mask", "bool", 1, "input"),
          array("user_mask", "bool", 1, "input"),
          array("user_to_backend", "int32", 1, "input"),
          boolean("has_ordering"),
          array("user_data", "float32", 2, "output"),
          array("backend_data", "float32", 2, "output"),
        ],
      )
    "joint-velocity-mask" =>
      (
        "mr_g1_joint_velocity_mask",
        ordering_path(),
        "write_joint_vel_user_to_backend_with_mask",
        matrix,
        [
          array("in_data", "float32", 2, "input"),
          array("env_mask", "bool", 1, "input"),
          array("user_mask", "bool", 1, "input"),
          array("user_to_backend", "int32", 1, "input"),
          boolean("has_ordering"),
          array("user_vel", "float32", 2, "output"),
          array("user_prev_vel", "float32", 2, "output"),
          array("user_acc", "float32", 2, "output"),
          array("backend_vel", "float32", 2, "output"),
        ],
      )
    "joint-target-mask" =>
      (
        "mr_g1_joint_target_mask",
        collection_path(),
        "write_2d_float_with_mask",
        matrix,
        [
          array("source", "float32", 2, "input"),
          array("env_mask", "bool", 1, "input"),
          array("joint_mask", "bool", 1, "input"),
          array("target", "float32", 2, "output"),
        ],
      )
    "implicit-actuator-batch" =>
      (
        "mr_g1_implicit_actuator_batch",
        collection_path(),
        "compute_implicit_actuator_batch",
        matrix,
        [
          array("command_pos", "float32", 2, "input"),
          array("command_vel", "float32", 2, "input"),
          array("command_effort", "float32", 2, "input"),
          array("joint_pos", "float32", 2, "input"),
          array("joint_vel", "float32", 2, "input"),
          array("joint_stiffness", "float32", 2, "input"),
          array("joint_damping", "float32", 2, "input"),
          array("joint_effort_limits", "float32", 2, "input"),
          array("velocity_limit", "float32", 2, "input"),
          array("joint_indices", "int32", 1, "input"),
          array("batch_computed_effort", "float32", 2, "output"),
          array("batch_applied_effort", "float32", 2, "output"),
          array("target_pos", "float32", 2, "output"),
          array("target_vel", "float32", 2, "output"),
          array("target_effort", "float32", 2, "output"),
          array("computed_effort", "float32", 2, "output"),
          array("applied_effort", "float32", 2, "output"),
          array("soft_velocity_limit", "float32", 2, "output"),
        ],
      )
    "joint-target-reorder" =>
      (
        "mr_g1_joint_target_reorder",
        ordering_path(),
        "reorder_joint_targets_user_to_backend",
        matrix,
        [
          array("user_effort", "float32", 2, "input"),
          array("user_pos_target", "float32", 2, "input"),
          array("user_vel_target", "float32", 2, "input"),
          array("backend_to_user", "int32", 1, "input"),
          boolean("write_effort"),
          boolean("write_pos_target"),
          boolean("write_vel_target"),
          boolean("write_joint_act"),
          array("backend_effort", "float32", 2, "output"),
          array("backend_pos_target", "float32", 2, "output"),
          array("backend_vel_target", "float32", 2, "output"),
          array("backend_joint_act", "float32", 2, "output"),
        ],
      )
    "torque-telemetry" =>
      (
        "mr_g1_torque_telemetry",
        actuator_path(),
        "sync_torque_telemetry",
        matrix,
        [
          array("joint_pos_backend", "float32", 2, "input"),
          array("joint_vel_backend", "float32", 2, "input"),
          array("joint_pos_target", "float32", 2, "input"),
          array("joint_vel_target", "float32", 2, "input"),
          array("joint_stiffness", "float32", 2, "input"),
          array("joint_damping", "float32", 2, "input"),
          array("effort_limit", "float32", 2, "input"),
          array("joint_modes", "int32", 1, "input"),
          array("sim_bind_joint_effort", "float32", 2, "input"),
          array("actuator_computed_effort", "float32", 2, "input"),
          array("user_to_backend", "int32", 1, "input"),
          boolean("sim_buffers_are_backend_order"),
          array("computed", "float32", 2, "output"),
          array("applied", "float32", 2, "output"),
        ],
      )
    "publish-joint-state" =>
      (
        "mr_g1_publish_joint_state",
        ordering_path(),
        "reorder_joint_state_backend_to_user",
        matrix,
        [
          array("backend_pos", "float32", 2, "input"),
          array("backend_vel", "float32", 2, "input"),
          array("user_to_backend", "int32", 1, "input"),
          array("user_pos", "float32", 2, "output"),
          array("user_vel", "float32", 2, "output"),
        ],
      )
    "publish-body-state" =>
      (
        "mr_g1_publish_body_state",
        ordering_path(),
        "reorder_body_state_backend_to_user",
        [request.num_envs, request.num_bodies],
        [
          array("backend_pose", "transformf", 2, "input"),
          array("backend_vel", "spatial_vectorf", 2, "input"),
          array("user_to_backend", "int32", 1, "input"),
          array("user_pose", "transformf", 2, "output"),
          array("user_vel", "spatial_vectorf", 2, "output"),
        ],
      )
    "publish-joints" | "publish-body-pose" | "publish-body-velocity" => {
      let dtype = match key {
        "publish-joints" => "float32"
        "publish-body-pose" => "transformf"
        _ => "spatial_vectorf"
      }
      let symbol = match key {
        "publish-joints" => "mr_g1_publish_joints"
        "publish-body-pose" => "mr_g1_publish_body_pose"
        _ => "mr_g1_publish_body_velocity"
      }
      let width = if key == "publish-joints" {
        request.num_joints
      } else {
        request.num_bodies
      }
      (
        symbol,
        ordering_path(),
        "gather_2d",
        [request.num_envs, width],
        [
          array("src", dtype, 2, "input"),
          array("dst_to_src", "int32", 1, "input"),
          array("dst", dtype, 2, "output"),
        ],
      )
    }
    _ => raise LowerError::Invalid("unsupported concrete kernel: " + key)
  }
  {
    key,
    forward,
    upstream_file: path,
    upstream_function: function,
    upstream_file_sha256: file_sha(path),
    launch_shape: shape,
    parameters,
  }
}

///|
/// Supported keys are fixed; no arbitrary code, symbols or type names are
/// interpolated from user input. Three gather specializations cover publication.
pub fn supported_kernels() -> Array[String] {
  [
    "root-pose-mask", "root-velocity-mask", "joint-position-mask", "joint-velocity-mask",
    "joint-target-mask", "implicit-actuator-batch", "joint-target-reorder", "torque-telemetry",
    "publish-joint-state", "publish-body-state", "publish-joints", "publish-body-pose",
    "publish-body-velocity",
  ]
}

///|
/// Lower fixed typed hooks to CUDA C++ against real Warp 1.17 builtin headers.
/// Every launch uses coord_mult=1 and a grid-stride loop matching Warp indexing.
pub fn lower(request : SpecializationRequest) -> Specialization raise {
  guard request.num_envs > 0 &&
    request.num_joints == 29 &&
    request.num_bodies > 0 &&
    request.num_envs <= 2147483647 / request.num_joints &&
    request.num_envs <= 2147483647 / request.num_bodies else {
    raise LowerError::Invalid(
      "positive G1 dimensions required, num_joints=29, total launch cells <= INT32_MAX",
    )
  }
  guard !request.kernels.is_empty() else {
    raise LowerError::Invalid("at least one concrete kernel required")
  }
  let keys : Map[String, Unit] = {}
  let entries : Array[Entry] = []
  for key in request.kernels {
    guard !keys.contains(key) else {
      raise LowerError::Invalid("duplicate kernel key: " + key)
    }
    keys[key] = ()
    entries.push(entry(request, key))
  }
  let blocks : Array[String] = [
    "// Generated by MoonBit's pinned G1 typed lowerer; not Warp Python AST codegen.\n// Copyright (c) 2022-2026, The Isaac Lab Project Developers.\n// All rights reserved. SPDX-License-Identifier: BSD-3-Clause\n// Source semantics derived from IsaacLab kernels; see receipt and NOTICE.\n#define WP_NO_CRT\n#include \"builtin.h\"\nstatic_assert(sizeof(wp::array_t<float>)==56, \"Warp 1.17 64-bit array ABI required\");\nstatic_assert(sizeof(bool)==1, \"CUDA C++ bool ABI required\");\nstatic_assert(sizeof(wp::transformf)==28 && sizeof(wp::spatial_vectorf)==24, \"Warp float vector ABI required\");\n",
  ]
  for e in entries {
    let dimension = e.launch_shape.length()
    let signature = e.parameters.map(p => p.c_type + " " + p.name).join(", ")
    let setup = if dimension == 1 {
      "const int i=coord.i;\n"
    } else {
      "const int i=coord.i; const int j=coord.j;\n"
    }
    blocks.push(
      "extern \"C\" __global__ void " +
      e.forward +
      "(wp::launch_bounds_t<\{dimension}> dim, " +
      signature +
      ") {\nfor(size_t linear=size_t(blockIdx.x)*blockDim.x+threadIdx.x;linear<dim.size;linear+=size_t(blockDim.x)*gridDim.x){\nauto coord=wp::launch_coord(linear,dim);\n" +
      setup +
      body(e.key) +
      "\n}\n}\n",
    )
  }
  let source = blocks.join("\n")
  let source_sha256 = @artifacts.sha256(@utf8.encode(source))
  let identity : Json = {
    "format": "moonrobo-g1-concrete-kernels-v1",
    "request": request.to_json(),
    "entries": entries.to_json(),
    "source_sha256": source_sha256.to_json(),
    "isaaclab_revision": isaaclab_revision().to_json(),
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
