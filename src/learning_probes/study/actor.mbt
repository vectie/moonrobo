///|
fn merged(base : Json, override : Json) -> Json raise {
  guard base is Object(a) && override is Object(b) else {
    fail("settings must be objects")
  }
  let result = a.copy()
  for k, v in b {
    result[k] = v
  }
  result.to_json()
}

///|
fn direction(
  model : @training.Dynamics,
  actor : @training.Actor,
  critic : @training.Critic,
  starts : Array[@training.ActorStart],
  config : Json,
  bootstrap : Bool,
) -> @probes.AdamDirection raise {
  let _ = objective(
    model,
    actor,
    critic,
    starts,
    actor.network.parameters,
    config,
    bootstrap,
  )
  @probes.adam_direction(
    actor.network.parameters,
    p => try! objective(model, actor, critic, starts, p, config, bootstrap),
    num(config, "actor_learning_rate"),
    int(config, "horizon"),
  )
}

///|
/// Fresh optimizer actor updates compared on identical restored physical origins.
/// Paired mode adds initial/adapted models, both bootstrap flags and full horizons.
pub async fn run_actor(
  options : Map[String, String],
  paired~ : Bool = false,
) -> Unit {
  let config = read(option(options, "--config"))
  let experiment = read(option(options, "--experiment"))
  let batch = @artifacts.load_window_batch(option(options, "--train"), "train")
  let windows = @training.windows_from_batch(batch)
  if windows.is_empty() {
    fail("empty replay")
  }
  let runtime = @physics.Runtime::open(
    option(options, "--library"),
    option(options, "--scene"),
  )
  let dt = num(experiment, "control_dt_s")
  let output = option(options, "--output")
  if !@fs.exists(output) {
    @fs.mkdir(output, recursive=true)
  }
  let records : Array[Json] = []
  let summaries : Array[Json] = []
  let saved_origins : Array[Json] = []
  let bindings : Array[Json] = []
  let checkpoints : Map[String, String] = {}
  let mut maximum_restore_error = 0.0
  for seed in ints(config, "policy_seeds") {
    let actor_path = checkpoint_path(
      option(options, "--policies"),
      "actor-seed-\{seed}",
    )
    let cp = @training.load_learning_checkpoint(actor_path, "g1-actor")
    let actor = @training.actor_from_checkpoint(cp)
    let critic = @training.critic_from_actor_checkpoint(
      cp,
      actor.goal_stats.mean.length(),
      2,
    )
    let settings = merged(field(cp.metadata, "config"), config)
    if paired && settings is Object(m) {
      m["actor_critic_bootstrap"] = true.to_json()
    }
    let full_settings = merged(settings, {
      "horizon": if paired {
        int(config, "full_horizon")
      } else {
        int(settings, "horizon")
      },
      "actor_critic_bootstrap": false,
    })
    let horizon = int(settings, "horizon")
    let origins : Array[Snapshot] = []
    let references : Array[Array[@physics.Transition]] = []
    let omitted : Array[Json] = []
    for case in arr(experiment, "cases") {
      if str(case, "split") != "train" {
        continue
      }
      if !["stand", "pose_offset"].contains(str(case, "motion")) {
        fail("actor update probe requires constant-goal training families")
      }
      for reset_seed in ints(config, "reset_seeds") {
        let collection = collect(
          runtime,
          case,
          reset_seed,
          experiment,
          ints(config, "snapshot_steps"),
          Some(actor),
        )
        for start in ints(config, "snapshot_steps") {
          if collection.snapshots.filter(s => s.step == start).get(0) is Some(s) {
            origins.push(s)
            let n = if start + horizon > collection.episode.steps.length() {
              collection.episode.steps.length() - start
            } else {
              horizon
            }
            references.push(
              Array::makei(n, i => collection.episode.steps[start + i]),
            )
          } else {
            omitted.push({
              "case": str(case, "id"),
              "reset_seed": reset_seed,
              "start_step": start,
            })
          }
        }
      }
    }
    if origins.is_empty() {
      fail("no physical origins")
    }
    let recent : Array[@training.ActorStart] = origins.map(s => {
      state: s.state,
      previous: s.previous,
      goal: s.goal,
      context: s.context,
    })
    let rng = @numeric.Rng::new(
      (int(config, "sampling_seed") + seed).to_uint() + 1U,
    )
    let n = if paired {
      int(config, "direction_batch_size")
    } else {
      origins.length()
    }
    let nu = actor.goal_stats.mean.length()
    let obs_width = batch.observation.length() / (batch.count * batch.horizon)
    let offline : Array[@training.ActorStart] = []
    for _ in 0..<n {
      let index = rng.index(windows.length())
      let w = windows[index]
      let obs_offset = index * batch.horizon * obs_width
      let goal_offset = index * batch.horizon * nu
      offline.push({
        state: w.state[0],
        previous: Array::makei(nu, i => {
          batch.observation[obs_offset + obs_width - nu + i]
        }),
        goal: Array::makei(nu, i => batch.goal[goal_offset + i]),
        context: w.context,
      })
    }
    let baselines : Array[@probes.PhysicalOutcome] = []
    let full_baselines : Array[@probes.PhysicalOutcome] = []
    for i, s in origins {
      let (base, states, actions) = physical(
        runtime, s, actor, critic, settings, dt,
      )
      let err1 = max_error(states, references[i].map(r => r.next_state))
      let err2 = max_error(actions, references[i].map(r => r.applied_action))
      let error = if err1 > err2 { err1 } else { err2 }
      if error > 0.00000001 {
        fail("restored closed-loop physics differs")
      }
      if error > maximum_restore_error {
        maximum_restore_error = error
      }
      baselines.push(base)
      full_baselines.push(
        if paired {
          physical(runtime, s, actor, critic, full_settings, dt).0
        } else {
          base
        },
      )
    }
    let paths : Array[(String, String)] = if paired {
      [
        ("initial", option(options, "--initial")),
        (
          "adapted",
          checkpoint_path(option(options, "--adapted"), "dynamics-seed-\{seed}"),
        ),
      ]
    } else {
      [("dynamics", option(options, "--dynamics"))]
    }
    let directions = @artifacts.Checkpoint::new(
      "parameter-direction-collection",
      { "actor_sha256": digest(actor_path), "config": settings },
    )
    checkpoints[actor_path] = digest(actor_path)
    for (label, path) in paths {
      let model_cp = @training.load_learning_checkpoint(
        path, "residual-dynamics",
      )
      if str(model_cp.metadata, "training_batch_sha256") != batch.digest ||
        field(model_cp.metadata, "layout") != batch.layout {
        fail("probe replay differs from frozen world model")
      }
      let model_digest = digest(path)
      if paired &&
        label == "adapted" &&
        str(cp.metadata, "paired_dynamics_sha256") != model_digest {
        fail("actor is not paired with adapted model")
      }
      let model = @training.dynamics_from_checkpoint(model_cp)
      bindings.push({
        "policy_seed": seed,
        "model": label,
        "dynamics_sha256": model_digest,
        "policy_sha256": digest(actor_path),
        "selected_update": field(cp.metadata, "selected_update"),
        "model_round": optional(
          model_cp.metadata,
          "online_model_round",
          (0).to_json(),
        ),
      })
      let distributions : Array[(String, Array[@training.ActorStart])] = if paired {
        [("replay", offline)]
      } else {
        [("replay", offline), ("on-policy", recent)]
      }
      for (distribution, starts) in distributions {
        let flags : Array[Bool] = if paired {
          @json.from_json(field(config, "direction_bootstrap"))
        } else {
          [boolean(settings, "actor_critic_bootstrap", true)]
        }
        for bootstrap in flags {
          let update = direction(
            model, actor, critic, starts, settings, bootstrap,
          )
          let key = if paired {
            "\{label}-bootstrap-\{bootstrap}"
          } else {
            distribution
          }
          directions.put(key, [update.delta.length()], update.delta)
          let recent_before = objective(
              model,
              actor,
              critic,
              recent,
              actor.network.parameters,
              settings,
              bootstrap,
            ).0
          for multiplier in nums(config, "multipliers") {
            let next = candidate(actor, update.delta, multiplier)
            let predicted = objective(
                model,
                next,
                critic,
                starts,
                next.network.parameters,
                settings,
                bootstrap,
              ).0
            let predicted_recent = objective(
                model,
                next,
                critic,
                recent,
                next.network.parameters,
                settings,
                bootstrap,
              ).0
            let reward_change = objective(
                model,
                next,
                critic,
                recent,
                next.network.parameters,
                settings,
                false,
              ).0 -
              objective(
                model,
                actor,
                critic,
                recent,
                actor.network.parameters,
                settings,
                false,
              ).0
            let boot_change = objective(
                model,
                next,
                critic,
                recent,
                next.network.parameters,
                settings,
                true,
              ).0 -
              objective(
                model,
                actor,
                critic,
                recent,
                actor.network.parameters,
                settings,
                true,
              ).0
            let outcomes : Array[@probes.PhysicalOutcome] = []
            let full_outcomes : Array[@probes.PhysicalOutcome] = []
            for i, s in origins {
              let after = if multiplier == 0 {
                baselines[i]
              } else {
                physical(runtime, s, next, critic, settings, dt).0
              }
              let full = if !paired {
                after
              } else if multiplier == 0 {
                full_baselines[i]
              } else {
                physical(runtime, s, next, critic, full_settings, dt).0
              }
              outcomes.push(after)
              full_outcomes.push(full)
              records.push({
                "policy_seed": seed,
                "model": label,
                "direction_bootstrap": bootstrap,
                "distribution": distribution,
                "multiplier": multiplier,
                "case": s.case_id,
                "reset_seed": s.seed,
                "start_step": s.step,
                "baseline": baselines[i],
                "candidate": after,
                "full_baseline": full_baselines[i],
                "full_candidate": full,
              })
            }
            let reward = Array::makei(origins.length(), i => {
              outcomes[i].reward_return - baselines[i].reward_return
            })
            let boot = Array::makei(origins.length(), i => {
              outcomes[i].bootstrapped_return - baselines[i].bootstrapped_return
            })
            let full = Array::makei(origins.length(), i => {
              full_outcomes[i].reward_return - full_baselines[i].reward_return
            })
            summaries.push({
              "policy_seed": seed,
              "model": label,
              "direction_bootstrap": bootstrap,
              "distribution": distribution,
              "multiplier": multiplier,
              "origins": origins.length(),
              "omitted_origins": omitted.length(),
              "direction_batch_size": n,
              "gradient_norm": update.gradient_norm,
              "actor_gradient_norm": update.gradient_norm,
              "fit_objective": update.objective_before,
              "model_fit_objective_change": predicted - update.objective_before,
              "model_recent_objective_change": predicted_recent - recent_before,
              "predicted_recent_reward_change": reward_change,
              "predicted_recent_bootstrapped_change": boot_change,
              "physical_bootstrapped_change": average(boot),
              "physical_reward_change": average(reward),
              "physical_improves_fraction": average(
                boot.map(v => if v > 0 { 1.0 } else { 0.0 }),
              ),
              "full_physical_reward_change": average(full),
              "full_reward_improves_fraction": average(
                full.map(v => if v > 0 { 1.0 } else { 0.0 }),
              ),
              "mean_full_steps_change": average(
                Array::makei(origins.length(), i => {
                  (full_outcomes[i].steps - full_baselines[i].steps).to_double()
                }),
              ),
              "baseline_falls": baselines.filter(b => b.failed).length(),
              "candidate_falls": outcomes.filter(b => b.failed).length(),
              "full_baseline_falls": full_baselines
              .filter(b => b.failed)
              .length(),
              "full_candidate_falls": full_outcomes
              .filter(b => b.failed)
              .length(),
              "window_baseline_falls": baselines.filter(b => b.failed).length(),
              "window_candidate_falls": outcomes.filter(b => b.failed).length(),
            })
          }
        }
      }
    }
    ignore(
      @artifacts.save_checkpoint(
        output + "/directions-seed-\{seed}.moon.json",
        directions,
      ),
    )
    let origin_json : Array[Json] = origins.map(s => {
      "case": s.case_id,
      "reset_seed": s.seed,
      "start_step": s.step,
      "time_s": s.step.to_double() * dt,
      "state": s.state,
      "integration": s.integration,
      "previous": s.previous,
      "goal": s.goal,
      "context": s.context,
    })
    saved_origins.push({
      "policy_seed": seed,
      "origins": origin_json,
      "omitted": omitted,
    })
  }
  let report : Json = {
    "format": if paired {
      "moonrobo.g1-paired-model-probe.v1"
    } else {
      "moonrobo.g1-actor-update-probe.v1"
    },
    "config": config,
    "experiment": experiment,
    "training_batch_sha256": batch.digest,
    "checkpoint_sha256": checkpoints,
    "bindings": bindings,
    "maximum_restore_error": maximum_restore_error,
    "summaries": summaries,
    "origins": saved_origins,
    "records": records,
    "physical_execution_allowed": false,
    "scope": "Fresh-optimizer Adam directions, fixed critic, exact restored physics origins; separate physical reward and critic tails. MoonBit float64/native checkpoints with xorshift32 replay sampling.",
  }
  if !paired && report is Object(m) {
    m["dynamics_sha256"] = digest(option(options, "--dynamics")).to_json()
  }
  write(output + "/report.json", report)
  if report is Object(m) {
    ignore(m.remove("records"))
    ignore(m.remove("origins"))
  }
  write(output + "/summary.json", report)
}
