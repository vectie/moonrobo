///|
#borrow(path)
extern "c" fn install_allocator_cap(path : Bytes) -> Int64 = "mr_install_compiled_allocator"

///|
extern "c" fn start_bf16_watch() -> Bool = "mr_start_bf16_watch"

///|
async fn bf16_allocator_cap(root : String, config : Json) -> Int64 {
  let path = root + "/libmoonrobo_bf16_cap.so"
  let pin : String = setting(config, "compiled_allocator_sha256", "")
  guard valid_checkpoint_sha(pin) && file_hash(path) == pin else {
    fail("compiled allocator guard SHA256 mismatch")
  }
  let actual = install_allocator_cap(@utf8.encode(path + "\x00"))
  guard actual == 21474836480L else {
    fail("unable to verify native CUDA allocator cap (status \{actual})")
  }
  actual
}

///|
// The indices correspond to distinct exported forward/VJP contracts, not to
// interchangeable models. These pins include the layout-corrected actor pair.
fn bf16_packages() -> Array[(String, String)] {
  [
    (
      "hotspot-mlp-geometry-world-backward-export-a/rollout", "78bb407fb7ebc3e724ee1c2a2a20beed240b787c9c4f494b60b246069d62a551",
    ),
    (
      "hotspot-mlp-geometry-world-backward-export-a/error", "898975c7cfff1379f252582a053d99d60652d838a7ad5f7c941e4c24dc597e1d",
    ),
    (
      "hotspot-mlp-geometry-actor-layouts-b/initial", "e73ddeebb00b69d1316e17a311fd519ebf7a7ba618db0be9181744b204ed1653",
    ),
    (
      "hotspot-mlp-geometry-actor-layouts-b/recurrent", "16e69dc2d7e645ea19112439c792009851882cf130fe1400674de2153953421a",
    ),
    (
      "hotspot-mlp-geometry-world-reward-graph-export-b/reward", "a611e835f35014cfc2a86855eb8f3d7a662c38f5e7cf14e721ae51c53da1f51e",
    ),
    (
      "hotspot-mlp-geometry-world-actor-graphs-export-b/features", "e53f7810d65b8ea46b4ee6bf423c2dab8a4f234488f9e5427b6067ec6e6b3d87",
    ),
  ]
}

///|
fn bf16_profile(
  config : Json,
  s : Settings,
  args : Array[String],
) -> String? raise {
  let version : String = setting(config, "compiled_bf16_profile", "none")
  let root = option(args, "--compiled-bundle")
  if version == "none" {
    guard root is None else {
      fail("--compiled-bundle requires compiled_bf16_profile")
    }
    return None
  }
  let c = s.learner
  let o = s.optimizations
  guard version == "g1-corrected-v1" &&
    s.device == 0 &&
    s.distributed is None &&
    s.capacity_profile == @capacity.Paper4096 &&
    s.memory_admission_percent is Some(_) &&
    fp32_request(config) == Some(false) &&
    s.mode == @aligned.Smc &&
    o.mlp_precision == @gpu.Bf16 &&
    o.layer_norm_mode == @gpu.Native &&
    o.world_linear_mode == @gpu.NativeLinear &&
    o.policy_linear_mode == @gpu.NativeLinear &&
    o.critic_linear_mode == @gpu.NativeLinear &&
    o.heading_mode == @geometry.OrthonormalAtlas &&
    o.rotation_error_mode == @geometry.GeodesicSquared &&
    o.tail_reference_fk_cache &&
    o.reuse_geometry &&
    o.smc_xi_normalization &&
    o.smc_actor_return &&
    !o.smc_world_rotation &&
    !o.critic_cuda_graph &&
    !o.batch_actor_encoder &&
    !o.actor_norm_snapshot &&
    c.wm_batch == 2048 &&
    c.policy_batch == 4096 &&
    c.wm_window == 8 &&
    c.horizon == 32 &&
    c.hist == 10 &&
    c.goal_frames == 10 &&
    c.observation_noise &&
    c.wm_hidden == [2048, 2048, 2048] &&
    c.policy_hidden == [2048, 1024, 512, 256] &&
    c.critic_hidden == [256, 128] &&
    c.critic_epochs == 5 &&
    c.critic_minibatches == 4 &&
    c.wm_batches == 10 &&
    s.batch_execution.world_microbatch == 0 &&
    s.batch_execution.actor_microbatch == 0 &&
    s.resident_reference_max_bytes is None else {
    fail(
      "g1-corrected-v1 requires the fixed single-GPU BF16 full4096/H32 and world2048/W8 contract, IEEE geometry, streamed references and telemetry",
    )
  }
  guard root is Some(path) && path.has_prefix("/") else {
    fail("absolute read-only --compiled-bundle required")
  }
  Some(path)
}

///|
async fn verify_bf16_bundle(root : String) -> Json {
  let pins : Map[String, String] = {}
  for (relative, expected) in bf16_packages() {
    let path = root + "/" + relative
    let hash = @crypto.SHA256::new()
    let names = @fs.readdir(path)
    // sha256sum inventory was generated under LC_ALL=C; default MoonBit
    // ordering compares string length first.
    names.sort_by((a, b) => a.lexical_compare(b))
    guard names.length() <= 2048 else {
      fail("compiled directory exceeds inventory bound")
    }
    for name in names {
      if name.has_suffix(".so") ||
        name.has_suffix(".cubin") ||
        name == "manifest.json" ||
        name == "native.spec" {
        let file = path + "/" + name
        guard @fs.kind(file, follow_symlink=false) == Regular else {
          fail("compiled input must be a regular file")
        }
        ignore(bounded_physics_file(file, 67108864L))
        hash.update(@utf8.encode(file_hash(file) + "  " + name + "\n"))
      }
    }
    guard @crypto.bytes_to_hex_string(hash.finalize()) == expected else {
      fail("compiled package SHA256 differs: " + relative)
    }
    pins[relative] = expected
  }
  Json(pins)
}

///|
// Install only after all checks succeed. No shared-fixture weights, replay,
// normalizers, fixed reference tensors or optimizer state enter the trainer.
async fn install_bf16_bundle(learner : @gpu.Learner, root : String) -> Unit {
  let dirs = bf16_packages().map(entry => root + "/" + entry.0)
  let reward = bounded_json(dirs[4] + "/manifest.json", 1048576L)
  let model = identity_field(reward, "model_contract")
  guard identity_field(
      bounded_json(dirs[5] + "/manifest.json", 1048576L),
      "model_contract",
    ) ==
    model else {
    fail("reward and critic model contracts differ")
  }
  let constants = learner.context.compiled_reward_constants(
    @json.from_json(identity_field(model, "names")),
    @json.from_json(identity_field(model, "parents")),
    @json.from_json(identity_field(model, "joints")),
    @json.from_json(identity_field(model, "tracked")),
    @json.from_json(identity_field(model, "reward")),
  )
  let blocks = dirs.map(path => {
    learner.backend.load_compiled_block(path, cuda_device=learner.cuda_device)
  })
  learner.world.compiled_fitting_window = Some((blocks[0], blocks[1]))
  learner.compiled_actor_steps = Some((blocks[2], blocks[3]))
  learner.compiled_actor_reward = Some((blocks[4], constants))
  learner.compiled_critic_features = Some(blocks[5])
  learner.critic.norm.smc_statistics = true
  learner.smc_gae_order = true
  learner.smc_adam = true
}
