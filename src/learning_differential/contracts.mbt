///|
pub(all) struct CaseContract {
  id : String
  original_method : String
  required : Array[String]
} derive(ToJson, Debug)

///|
pub fn contracts() -> Array[CaseContract] {
  [
    {
      id: "data.resampling",
      original_method: "AlignedDataTest.test_resampling_velocity_goals_and_end_bins",
      required: [
        "clip_len", "num_bins", "frame_bin_end", "root_v", "goals", "future_frames",
        "sampled_frames", "sampled_min32",
      ],
    },
    {
      id: "data.duplicates",
      original_method: "AlignedDataTest.test_duplicate_bin_update_is_order_independent_and_checkpoint_exact",
      required: [
        "bin_G", "bin_G_reversed", "completed_count", "probabilities", "sample_after_restore",
        "sample_replica",
      ],
    },
    {
      id: "data.bootstrap",
      original_method: "AlignedDataTest.test_timeout_bootstrap_and_real_terminal",
      required: ["bin_G"],
    },
    {
      id: "data.manifest",
      original_method: "AlignedDataTest.test_manifest_hash_verification_and_split_identity",
      required: ["names_utf8", "split_utf8", "changed_sha_rejected"],
    },
    {
      id: "data.reference_only",
      original_method: "AlignedDataTest.test_reference_only_export_skips_fk_without_changing_goal_features",
      required: [
        "body_features_absent", "full_goals", "light_goals", "fk_calls",
      ],
    },
    {
      id: "data.catalog40",
      original_method: "SmcDataDifferentialTest.test_all_40_acquired_sources_match_frozen_catalog",
      required: [
        "clip_count", "source_frame_count", "resampled_frame_count", "all_sha_valid",
        "split_equal", "source_revision_utf8",
      ],
    },
    {
      id: "data.real_clips",
      original_method: "SmcDataDifferentialTest.test_real_clip_reference_states_and_goals_against_smc",
      required: [
        "clip_len", "clip_start", "clip_end", "clip_id", "root_p", "root_R", "root_v",
        "root_w", "q", "qd", "root_v_local", "root_w_local", "root_gz", "future_frames",
        "goals",
      ],
    },
    {
      id: "data.reset_mixture",
      original_method: "SmcDataDifferentialTest.test_reset_mixture_and_unique_return_updates_match_actual_smc_method",
      required: [
        "sampled_frames", "sampled_bins", "bin_w_avg", "bin_G", "rng.after",
      ],
    },
    {
      id: "data.terminal_fix",
      original_method: "SmcDataDifferentialTest.test_terminal_only_bins_are_explicit_upstream_bug_fix",
      required: [
        "clip_len", "upstream_bin_start", "candidate_bin_start", "upstream_terminal_sampled",
        "candidate_terminal_sampled",
      ],
    },
    {
      id: "mdp.heads",
      original_method: "AlignedMDPDifferentialTest.test_head_values_and_gradients_match_smc_away_from_rotation_singularities",
      required: [
        "observation", "noisy_observation", "termination", "soft_termination", "reward",
        "term.track", "term.e_body_pos", "term.e_body_ori", "term.e_root_pos", "term.action_rate",
        "term.joint_limit", "critic_features", "gradient.p", "gradient.rotation_vector",
        "gradient.q",
      ],
    },
    {
      id: "mdp.observation_modes",
      original_method: "AlignedMDPDifferentialTest.test_observation_modes_have_exact_upstream_prefix",
      required: ["paper", "smc", "observable", "dimensions"],
    },
    {
      id: "mdp.fk",
      original_method: "AlignedMDPDifferentialTest.test_fk_matches_actual_upstream_for_all_tracked_bodies",
      required: ["body_p", "body_R", "body_v", "body_w"],
    },
    {
      id: "mdp.quaternion",
      original_method: "AlignedMDPDifferentialTest.test_matrix_quaternion_values_and_pullback_match_upstream",
      required: ["quaternion", "pullback", "finite"],
    },
    {
      id: "mdp.rotation_fixes",
      original_method: "AlignedMDPDifferentialTest.test_documented_rotation_fixes_remove_upstream_floor_and_vertical_collapse",
      required: [
        "candidate_angle_sq", "candidate_gradient", "upstream_angle_sq", "upstream_gradient",
        "candidate_vertical_yaw", "upstream_vertical_determinant",
      ],
    },
    {
      id: "learning.architecture",
      original_method: "SmcLearningDifferentialTests.test_default_architecture_parameter_shapes_match_upstream",
      required: ["architecture.wm", "architecture.pi", "architecture.critic"],
    },
    {
      id: "learning.world8",
      original_method: "SmcLearningDifferentialTests.test_network_outputs_and_world_model_8step_adam_match",
      required: [
        "network.world.p", "network.world.R", "network.world.v", "network.world.w",
        "network.world.q", "network.world.qd", "network.policy", "network.critic",
        "metrics.wm_loss", "metrics.wm_err8",
      ],
    },
    {
      id: "learning.policy32",
      original_method: "SmcLearningDifferentialTests.test_32step_actor_and_gae_critic_updates_match_actual_smc_function",
      required: [
        "metrics.pi_loss", "metrics.imag_rew", "metrics.pi_gradnorm", "metrics.imag_survival",
      ],
    },
    {
      id: "learning.replay",
      original_method: "SmcLearningDifferentialTests.test_replay_same_windows_history_and_exact_ring_restore",
      required: [
        "windows.s", "windows.s1", "windows.a", "windows.xi", "windows.done", "windows.mask",
        "starts.s", "starts.a_prev", "starts.xi", "starts.f", "history.s", "history.a_prev",
        "history.xi", "history.f", "restored.starts.s", "restored.history.s",
      ],
    },
    {
      id: "isaac.solver",
      original_method: "IsaacProtocolTest.test_pinned_physics_config_uses_four_five_millisecond_solver_steps",
      required: ["solver.config", "bad_physics_dt_rejected"],
    },
    {
      id: "isaac.joint_order",
      original_method: "IsaacProtocolTest.test_gpu_joint_order_mismatch_is_rejected_before_raw_state_access",
      required: ["order_rejected", "raw_state_calls"],
    },
    {
      id: "isaac.missing",
      original_method: "IsaacProtocolTest.test_optional_backend_reports_missing_runtime_without_breaking_cpu_import",
      required: [
        "missing_sdk_rejected", "missing_cuda_rejected", "launch_calls",
      ],
    },
    {
      id: "isaac.transition",
      original_method: "IsaacProtocolTest.test_training_transition_preserves_pre_reset_state_and_timeout",
      required: [
        "out.f", "out.done", "out.term", "out.truncated", "env.f", "env.ep_step",
        "target", "sampler.update_count", "sampler.episode_lengths", "out.xi",
      ],
    },
    {
      id: "isaac.evaluation",
      original_method: "IsaacProtocolTest.test_evaluation_view_disables_randomization_and_training_timeout",
      required: [
        "settings", "xi", "first.done", "last.done", "last.frame", "exhausted.frame",
        "exhausted.reward",
      ],
    },
    {
      id: "isaac.resume",
      original_method: "IsaacProtocolTest.test_warm_resume_declares_refill_and_starts_new_episodes",
      required: [
        "exact_resume", "replay_refill_required", "physical_episodes_reset", "env.f",
        "sampler.marker", "collision_rejected",
      ],
    },
    {
      id: "isaac.context",
      original_method: "IsaacProtocolTest.test_context_writes_physics_and_warm_resume_resamples_only_episode_offsets",
      required: [
        "xi", "friction", "coms", "com_body_ids", "model_change_flags", "offsets_resampled",
      ],
    },
    {
      id: "isaac.raw_action",
      original_method: "IsaacProtocolTest.test_evaluation_passes_raw_action_without_collection_cap",
      required: ["out.a", "target"],
    },
    {
      id: "isaac.episode_context",
      original_method: "IsaacProtocolTest.test_episode_context_resamples_only_selected_environment_and_updates_physics",
      required: [
        "xi", "friction", "coms", "env_ids", "resampling_protocol_rejected",
      ],
    },
  ]
}

///|
pub fn contract(id : String) -> CaseContract raise {
  for item in contracts() {
    if item.id == id {
      return item
    }
  }
  fail("unknown original differential contract: " + id)
}

///|
fn validate_required(
  id : String,
  outputs : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  for name in contract(id).required {
    guard outputs.contains(name) else {
      fail("oracle omitted original contract output: " + name)
    }
  }
  if id == "learning.world8" || id == "learning.policy32" {
    let models = if id == "learning.world8" {
      ["wm"]
    } else {
      ["wm", "pi", "critic"]
    }
    for model in models {
      guard outputs
        .keys()
        .any(name => name.has_prefix("weights_after." + model + ".")) else {
        fail("oracle omitted post-update model state_dict: " + model)
      }
    }
    let trained = if id == "learning.world8" {
      ["wm"]
    } else {
      ["pi", "critic"]
    }
    for model in trained {
      for prefix in ["grad.raw.", "grad.clipped.", "optimizer_after."] {
        guard outputs.keys().any(name => name.has_prefix(prefix + model + ".")) else {
          fail("oracle omitted full gradients/Adam evidence: " + prefix + model)
        }
      }
    }
  }
}

///|
fn validate_learning_evidence(
  id : String,
  input : Map[String, @artifacts.NumericArray],
  outputs : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  if id != "learning.world8" && id != "learning.policy32" {
    return
  }
  validate_small_weight_keyset(input)
  let trained = if id == "learning.world8" { ["wm"] } else { ["pi", "critic"] }
  let models = if id == "learning.world8" {
    ["wm"]
  } else {
    ["wm", "pi", "critic"]
  }
  let epochs = number(input, "config.critic_epochs", default=2.0).to_int()
  let minibatches = number(input, "config.critic_minibatches", default=4.0).to_int()
  guard epochs <= 100 && minibatches <= 64 && epochs * minibatches <= 6400 else {
    fail("bounded original critic update count required")
  }
  for name, tensor in input {
    for model in models {
      let prefix = "weights." + model + "."
      if !name.has_prefix(prefix) {
        continue
      }
      let suffix = name[prefix.length():].to_owned()
      let after = get(outputs, "weights_after." + model + "." + suffix)
      guard after.shape == tensor.shape else {
        fail("post-update state_dict omitted/reshaped original tensor: " + name)
      }
      let parameter = suffix.has_prefix("net.") ||
        suffix.has_prefix("enc.") ||
        suffix.has_prefix("dec.")
      if !parameter || !trained.contains(model) {
        continue
      }
      for moment in ["exp_avg", "exp_avg_sq", "step"] {
        let before = get(
          input,
          "optimizer_before." + model + "." + suffix + "." + moment,
        )
        let after = get(
          outputs,
          "optimizer_after." + model + "." + suffix + "." + moment,
        )
        let wanted = if moment == "step" { [] } else { tensor.shape }
        guard before.shape == wanted && after.shape == wanted else {
          fail("complete Adam before/after tensor shape required: " + name)
        }
        if moment == "step" {
          guard number(
              input,
              "optimizer_before." + model + "." + suffix + ".step",
            ) ==
            0.0 else {
            fail(
              "original differential constructor Adam state must begin at step zero",
            )
          }
          ignore(
            number(outputs, "optimizer_after." + model + "." + suffix + ".step"),
          )
        }
      }
      let stages = if model == "critic" {
        Array::makei(epochs * minibatches, i => "step" + i.to_string() + ".")
      } else {
        [""]
      }
      for stage in stages {
        for kind in ["raw", "clipped"] {
          let gradient = get(
            outputs,
            "grad." + kind + "." + model + "." + stage + suffix,
          )
          guard gradient.shape == tensor.shape else {
            fail(
              "complete raw/clipped parameter gradient evidence required: " +
              name,
            )
          }
        }
      }
    }
  }
}

///|
fn validate_small_weight_keyset(
  input : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  let skeleton = (dimensions : Array[Int32], layer_norm : Bool) => {
    (
      { dimensions, parameters: [], activation: Silu, layer_norm, } :
      @aligned.Network)
  }
  let wm = slots(skeleton([133, 16, 16, 16, 70], true), "net.").map(s => {
    (s.name, s.shape)
  })
  wm.append(norm_shapes("in_norm", 133))
  wm.append(norm_shapes("out_norm", 70))
  let pi = slots(skeleton([730, 16, 12, 32], false), "enc.").map(s => {
    (s.name, s.shape)
  })
  pi.append(
    slots(skeleton([962, 16, 12, 29], false), "dec.").map(s => (s.name, s.shape)),
  )
  pi.append(norm_shapes("obs_norm", 93))
  pi.append(norm_shapes("goal_norm", 730))
  let critic = slots(skeleton([914, 16, 8, 1], false), "net.").map(s => {
    (s.name, s.shape)
  })
  critic.append(norm_shapes("norm", 914))
  for (model, layout) in [("wm", wm), ("pi", pi), ("critic", critic)] {
    let prefix = "weights." + model + "."
    guard input.keys().filter(name => name.has_prefix(prefix)).count() ==
      layout.length() else {
      fail("complete original state_dict keyset required: " + model)
    }
    for (name, shape) in layout {
      guard get(input, prefix + name).shape == shape else {
        fail("original state_dict shape mismatch: " + prefix + name)
      }
    }
  }
}

///|
fn validate_case_inputs(
  id : String,
  input : Map[String, @artifacts.NumericArray],
) -> Unit raise {
  for name, tensor in input {
    if name == "inputs.critic_permutations" ||
      name.has_suffix(".f") ||
      name.has_suffix(".ep_step") ||
      name == "kin.parent" ||
      name == "kin.joint" ||
      name == "kin.tracked" ||
      name.has_suffix("_ages") ||
      name.has_suffix("_environments") ||
      name == "sampler.update_bins" ||
      name == "sampler.bin_start" ||
      name == "sampler.bin_clip_end" {
      guard ["<i4", "<i8"].contains(tensor.dtype) &&
        tensor.values.all(v => {
          v.trunc() == v && v >= -2147483648.0 && v <= 2147483647.0
        }) else {
        fail("exact Int32-range integer tensor required: " + name)
      }
    }
  }
  if id == "learning.world8" || id == "learning.policy32" {
    for
      (name, wanted) in [
        ("config.hist", 10.0),
        ("config.goal_frames", 10.0),
        ("config.horizon", 32.0),
        ("config.wm_window", 8.0),
        ("config.wm_batch", 2.0),
        ("config.pi_batch", 2.0),
        ("config.critic_epochs", 2.0),
        ("config.critic_minibatches", 4.0),
      ] {
      guard number(input, name) == wanted else {
        fail("original fixed test configuration differs: " + name)
      }
    }
    for
      (name, wanted) in [
        ("config.lr", 0.0002),
        ("config.gamma", 0.99),
        ("config.lam", 0.95),
        ("config.observation_noise", 0.0),
        ("config.no_critic", 0.0),
      ] {
      guard number(input, name) == wanted else {
        fail("original fixed scalar configuration differs: " + name)
      }
    }
    let required_shapes = if id == "learning.world8" {
      [
        ("inputs.state", [2, 71]),
        ("inputs.action", [2, 29]),
        ("inputs.xi_normalized", [2, 33]),
        ("inputs.observation_history", [2, 10, 93]),
        ("inputs.goal", [2, 730]),
        ("inputs.critic_features", [2, 914]),
        ("inputs.windows.s", [2, 8, 71]),
        ("inputs.windows.s1", [2, 8, 71]),
        ("inputs.windows.a", [2, 8, 29]),
        ("inputs.windows.xi", [2, 8, 33]),
        ("inputs.windows.mask", [2, 8]),
        ("inputs.error_floor", [70]),
      ]
    } else {
      [
        ("inputs.starts.s", [2, 71]),
        ("inputs.starts.a_prev", [2, 29]),
        ("inputs.starts.xi", [2, 33]),
        ("inputs.starts.f", [2]),
        ("inputs.history.s", [2, 10, 71]),
        ("inputs.history.a_prev", [2, 10, 29]),
        ("inputs.history.xi", [2, 10, 33]),
        ("inputs.history.f", [2, 10]),
      ]
    }
    for (name, shape) in required_shapes {
      guard get(input, name).shape == shape else {
        fail("original fixed tensor dimensions differ: " + name)
      }
    }
    if id == "learning.world8" {
      let floors = get(input, "inputs.error_floor").values
      for i, x in floors {
        let wanted = if i < 3 {
          0.003
        } else if i < 6 {
          0.005
        } else if i < 9 {
          0.02
        } else if i < 12 {
          0.05
        } else if i < 41 {
          0.003
        } else {
          0.05
        }
        guard x.to_float() == wanted.to_float() else {
          fail("original world-model error-floor profile differs")
        }
      }
    }
    if id == "learning.policy32" {
      let permutation = get(input, "inputs.critic_permutations")
      guard permutation.shape == [2, 64] else {
        fail("original critic permutations must be 2 x 64")
      }
      for epoch in 0..<2 {
        let seen : Map[Int32, Bool] = {}
        for x in permutation.values[epoch * 64:(epoch + 1) * 64] {
          let i = x.to_int()
          guard i >= 0 && i < 64 && !seen.contains(i) else {
            fail("critic permutation is not exact 0..63")
          }
          seen[i] = true
        }
      }
      for name in ["inputs.starts.f", "inputs.history.f"] {
        guard get(input, name).values.all(v => v >= 0.0 && v + 32.0 <= 99.0) else {
          fail("original FixtureMotion frame/horizon out of range")
        }
      }
    }
  }
}

///|
/// Original gates are hard-coded; a fixture cannot supply looser tolerances.
fn tolerance(id : String, name : String) -> (Double, Double) {
  if (id == "isaac.transition" && (name == "target" || name == "out.xi")) ||
    (id == "isaac.raw_action" && name == "target") {
    (1.0e-8, 1.0e-5)
  } else if id == "mdp.heads" {
    if name == "reward" {
      (2.0e-9, 0.0)
    } else if name.has_prefix("term.") {
      (1.0e-8, 0.0)
    } else if name == "critic_features" || name.has_prefix("gradient.") {
      (2.0e-8, 0.0)
    } else {
      (0.0, 0.0)
    }
  } else if id == "data.real_clips" && name == "goals" {
    (2.0e-6, 2.0e-6)
  } else if id == "data.resampling" && name == "root_v" {
    (1.0e-5, 0.0)
  } else if id == "learning.world8" && name.has_prefix("metrics.") {
    (0.5e-7, 0.0)
  } else if id == "learning.policy32" && name.has_prefix("metrics.") {
    (0.5e-6, 0.0)
  } else if (
      id == "data.duplicates" && (name == "bin_G" || name == "probabilities")
    ) ||
    id == "data.bootstrap" {
    (1.0e-5, 1.3e-6)
  } else if id == "mdp.rotation_fixes" &&
    (name == "candidate_angle_sq" || name == "candidate_gradient") {
    (0.0, 1.0e-6)
  } else {
    (0.0, 0.0)
  }
}
