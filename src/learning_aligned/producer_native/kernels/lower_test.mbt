///|
test "concrete G1 reset velocity retains physical side effects and ABI" {
  let module = @kernels.lower({
    num_envs: 4,
    num_joints: 29,
    num_bodies: 30,
    kernels: ["root-velocity-mask"],
  })
  let entry = module.entries[0]
  assert_eq(entry.upstream_function, "set_root_com_velocity_to_sim_mask")
  assert_eq(entry.launch_shape, [4])
  assert_eq(entry.parameters.map(p => p.name), [
    "data", "env_mask", "num_bodies", "root_com_velocity_w", "body_acc_w",
  ])
  assert_eq(entry.parameters[1].c_type, "wp::array_t<bool>")
  assert_eq(entry.parameters[4].rank, 2)
  assert_true(module.source.contains("if(wp::index(env_mask,i))"))
  assert_true(
    module.source.contains(
      "wp::index(body_acc_w,i,b)=wp::spatial_vectorf(0.0f)",
    ),
  )
}

///|
test "fused state publication preserves ordering direction and both outputs" {
  let module = @kernels.lower({
    num_envs: 3,
    num_joints: 29,
    num_bodies: 31,
    kernels: ["publish-joint-state", "publish-body-state"],
  })
  assert_eq(module.entries[0].launch_shape, [3, 29])
  assert_eq(module.entries[1].launch_shape, [3, 31])
  assert_eq(module.entries[1].parameters[0].dtype, "transformf")
  assert_eq(module.entries[1].parameters[1].dtype, "spatial_vectorf")
  assert_true(
    module.source.contains(
      "wp::index(user_pos,i,j)=wp::index(backend_pos,i,backend)",
    ),
  )
  assert_true(
    module.source.contains(
      "wp::index(user_pose,i,j)=wp::index(backend_pose,i,backend)",
    ),
  )
}

///|
test "reject unsupported and duplicate kernels before native compiler loading" {
  let requests : Array[@kernels.SpecializationRequest] = [
    {
      num_envs: 1,
      num_joints: 28,
      num_bodies: 30,
      kernels: ["root-pose-mask"],
    },
    { num_envs: 1, num_joints: 29, num_bodies: 30, kernels: ["mujoco-solver"], },
    {
      num_envs: 1,
      num_joints: 29,
      num_bodies: 30,
      kernels: ["root-pose-mask", "root-pose-mask"],
    },
    {
      num_envs: 2147483647,
      num_joints: 29,
      num_bodies: 30,
      kernels: ["root-pose-mask"],
    },
  ]
  for request in requests {
    try @kernels.lower(request) catch {
      _ => ()
    } noraise {
      _ => fail("invalid specialization accepted")
    }
  }
}
