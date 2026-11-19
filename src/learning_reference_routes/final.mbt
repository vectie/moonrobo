///|
/// Reconstruct archived actor updates exactly before a matched final-cycle gradient-route fork.
pub async fn run_final_route(
  diagnostic_path : String,
  library : String,
  scene : String,
  output : String,
) -> Unit {
  let diagnostic_path = @fs.realpath(diagnostic_path)
  let output = @fs.realpath(output)
  let started = @async.now()
  let charter = @artifacts.load_json(output + "/config.json")
  verify_hash(
    diagnostic_path + "/report.json",
    text(charter, "diagnostic_report_sha256"),
  )
  let diagnostic = @artifacts.load_json(diagnostic_path + "/report.json")
  let source = @fs.realpath(text(diagnostic, "source_study"))
  verify_hash(source + "/report.json", text(charter, "source_report_sha256"))
  let previous = @artifacts.load_json(source + "/report.json")
  let learning = merge(field(previous, "config"), {
    "actor_critic_tail": false,
    "actor_origin_sampling": "trajectory-states",
  })
  let config = merge(learning, charter)
  let references_path = text(diagnostic, "references")
  let (_, references) = @reference.load_references(references_path)
  verify_hash(
    references_path + "/manifest.json",
    text(previous, "reference_manifest_sha256"),
  )
  let incoming = initial_actor_path(source)
  verify_hash(incoming, text(previous, "initialization_sha256"))
  let source_records = record_map(previous)
  let runtime = @native_physics.Runtime::open(library, scene)
  let methods : Array[String] = @json.from_json(field(charter, "methods"))
  let seeds : Array[Int32] = @json.from_json(field(charter, "seeds"))
  let quality = field(previous, "quality_target")
  let records : Array[Json] = []
  let runs : Array[Json] = []
  let checks : Array[Json] = []
  let mut new_records = 0
  let mut reused_records = 0
  for method in methods {
    for seed in seeds {
      let original = @reference.select_run(previous, method, seed)
      let (actor, actor_meta) = @reference.load_reference_actor(incoming)
      let geometry = @reference.kinematics_from_spec(actor_meta.kinematics)
      let schedule = @reference.ReferenceSchedule::new(
        references.map(r => try! r.clip()),
        geometry,
        [0, 500, 1000],
        0.02,
      )
      let optimizer = @numeric.Adam::new(
        actor.parameters().length(),
        number(learning, "actor_learning_rate"),
      )
      let sampler = Sampler::new(23000 + seed, optional_adapter(config))
      let training_ids : Array[String] = []
      let reconstruction : Array[Json] = []
      let mut fork : (@reference.ReferenceActor, @numeric.Adam, Sampler)? = None
      let mut model : @training.Dynamics? = None
      let mut model_path = ""
      let mut final_batch : @reference.CollectedBatch? = None
      let mut fit : Json = Json::null()
      let mut start_actor = ""
      let mut start_optimizer = ""
      let mut start_sampler = ""
      let mut full_forward = 0.0
      let mut fork_active = 0
      for cycle in array(original, "cycles") {
        let cycle_number = integer(cycle, "cycle")
        let ids : Array[String] = @json.from_json(
          field(cycle, "training_episode_ids"),
        )
        let batch = @reference.restore_record_group(
          source,
          ids.map(id => source_records[id]),
          actor,
          schedule,
          number(learning, "gamma"),
        )
        training_ids.append(ids)
        let actor_path = child(
          source,
          text(field(cycle, "checkpoint"), "checkpoint"),
        )
        model_path = @reference.sibling_checkpoint(
          actor_path, "dynamics", cycle_number,
        )
        let (fixed_model, model_meta) = @reference.load_reference_dynamics(
          model_path,
        )
        guard field(model_meta, "training_episode_ids") ==
          training_ids.to_json() else {
          fail("saved model training records differ")
        }
        if cycle_number == integer(charter, "intervention_cycle") {
          let pinned = @reference.select_run(diagnostic, method, seed)
          verify_hash(model_path, text(pinned, "model_sha256"))
          let branch = actor.snapshot()
          let branch_optimizer = optimizer.snapshot()
          let branch_sampler = sampler.fork()
          guard branch.to_json() == actor.to_json() &&
            branch_optimizer.to_json() == optimizer.to_json() else {
            fail("actor/optimizer fork differs")
          }
          fork = Some((branch, branch_optimizer, branch_sampler))
          start_actor = @reference.state_digest(actor)
          start_optimizer = @reference.optimizer_digest(optimizer)
          start_sampler = sampler.digest()
          let peek = sampler.fork()
          ignore(
            peek.indices(
              batch.points.length(),
              integer(learning, "actor_calibration_batch_size"),
            ),
          )
          let first = actor_origin_ids(batch, learning, peek).map(i => {
            batch.points[i]
          })
          let (full, active, _) = objective(
            fixed_model,
            actor,
            first,
            geometry,
            schedule,
            learning,
            @reference.Full,
            false,
          )
          let (stopped, stopped_active, _) = objective(
            fixed_model,
            branch,
            first,
            geometry,
            schedule,
            learning,
            @reference.StopPolicyInputs,
            false,
          )
          guard full == stopped && active == stopped_active else {
            fail("fork changes forward objective")
          }
          full_forward = full
          fork_active = active
        }
        fit = optimize_actor(
          fixed_model,
          actor,
          optimizer,
          batch,
          geometry,
          schedule,
          learning,
          sampler,
          @reference.Full,
        )
        let checkpoint = field(cycle, "checkpoint")
        let actor_file = child(source, text(checkpoint, "checkpoint"))
        let (saved, _) = @reference.load_reference_actor(
          actor_file,
          expected_sha256=text(checkpoint, "sha256"),
        )
        // Exact gate is intentionally retained, including against imported Float32 checkpoints.
        guard actor.to_json() == saved.to_json() else {
          fail(
            "reconstructed actor tensors differ; original Float32 replay has not been reproduced",
          )
        }
        guard field(fit, "actor_origin_samples") ==
          field(field(cycle, "actor"), "actor_origin_samples") else {
          fail("reconstructed actor-origin draws differ")
        }
        reconstruction.push({
          "cycle": cycle_number.to_json(),
          "model_checkpoint": model_path.to_json(),
          "model_sha256": digest(model_path).to_json(),
          "training_episode_ids": ids.to_json(),
          "actor_origin_draws_identical": true,
          "actor_checkpoint": actor_file.to_json(),
          "checkpoint_sha256": text(checkpoint, "sha256").to_json(),
          "actor_state_sha256": @reference.state_digest(actor).to_json(),
          "all_tensors_identical": true,
        })
        model = Some(fixed_model)
        final_batch = Some(batch)
      }
      guard fork is Some((branch, branch_optimizer, branch_sampler)) &&
        model is Some(model) &&
        final_batch is Some(batch) else {
        fail("declared intervention cycle absent")
      }
      checks.push({
        "method": method.to_json(),
        "seed": seed.to_json(),
        "cycles": reconstruction.to_json(),
      })
      let matched : Json = {
        "matched_start_actor_sha256": start_actor.to_json(),
        "matched_start_optimizer_sha256": start_optimizer.to_json(),
        "matched_start_sampler_sha256": start_sampler.to_json(),
        "equal_fork_forward_objective": true,
        "fork_forward_objective": full_forward.to_json(),
        "fork_active_steps": fork_active.to_json(),
      }
      let full_checkpoint = merge(field(original, "checkpoint"), {
        "checkpoint": child(
          source,
          text(field(original, "checkpoint"), "checkpoint"),
        ).to_json(),
      })
      let full = merge(
        original,
        merge(matched, {
          "gradient_route": "full",
          "reused_final_evaluation": true,
          "reconstructed_final_actor_identical": true,
          "reconstruction": reconstruction.to_json(),
          "final_actor_fit": fit,
          "final_sampler_sha256": sampler.digest().to_json(),
          "checkpoint": full_checkpoint,
        }),
      )
      runs.push(full)
      for trial in array(original, "trials") {
        records.push(
          @reference.inherited_record(
            source_records[text(trial, "episode_id")],
            source,
          ),
        )
        reused_records += 1
      }
      let stopped_fit = optimize_actor(
        model,
        branch,
        branch_optimizer,
        batch,
        geometry,
        schedule,
        learning,
        branch_sampler,
        @reference.StopPolicyInputs,
      )
      guard field(stopped_fit, "actor_origin_samples") ==
        field(fit, "actor_origin_samples") &&
        branch_sampler.state() == sampler.state() else {
        fail("forked actor sampler draws differ")
      }
      let folder = output + "/" + method + "/seed-" + seed.to_string()
      @fs.mkdir(folder + "/policy", recursive=true)
      let path = folder +
        "/policy/actor-stop-cycle-" +
        integer(charter, "intervention_cycle").to_string() +
        ".moon.json"
      let sha = @reference.save_reference_actor(
        path,
        branch,
        actor_meta.kinematics,
        0.02,
        {
          "source_report_sha256": text(charter, "source_report_sha256").to_json(),
          "source_method": method.to_json(),
          "seed": seed.to_json(),
          "cycle": field(charter, "intervention_cycle"),
          "final_cycle_route": "stop-policy-inputs",
          "training_episode_ids": training_ids.to_json(),
        },
        critic_status="unused by fixed no-tail objective",
      )
      let (restored, _) = @reference.load_reference_actor(
        path,
        expected_sha256=sha,
      )
      guard @reference.state_digest(restored) == @reference.state_digest(branch) else {
        fail("stopped actor reload differs")
      }
      let update_path = folder + "/policy/actor-update-state.moon.json"
      let update_state : Json = {
        "format": "moonrobo.moonbit-fixed-model-actor-update-state.v1",
        "optimizer": branch_optimizer.to_json(),
        "sampler_state": branch_sampler.state(),
        "sampler_adapter": branch_sampler.adapter.to_json(),
        "paired_actor_sha256": sha.to_json(),
        "fixed_model_checkpoint": model_path.to_json(),
        "fixed_model_sha256": digest(model_path).to_json(),
        "source_report_sha256": text(charter, "source_report_sha256").to_json(),
        "config": merge(learning, {
          "actor_feedback_gradient": "stop-policy-inputs",
        }),
        "scope": "actor optimizer/sampler under imported fixed model; not full worker restart",
      }
      let update_sha = @artifacts.save_json(update_path, update_state)
      let saved_state = @artifacts.load_json(
        update_path,
        expected_sha256=update_sha,
      )
      let restored_optimizer : @numeric.Adam = @json.from_json(
        field(saved_state, "optimizer"),
      )
      guard @reference.optimizer_digest(restored_optimizer) ==
        @reference.optimizer_digest(branch_optimizer) &&
        field(saved_state, "sampler_state") == branch_sampler.state() else {
        fail("actor update-state reload differs")
      }
      let behavior : Json = {
        "checkpoint": path.to_json(),
        "sha256": sha.to_json(),
        "state_sha256": @reference.state_digest(branch).to_json(),
      }
      let origins = @reference.seconds_steps(field(quality, "origins_s"), 0.02)
      let group = @reference.physical_group(
        runtime,
        references,
        schedule,
        restored,
        geometry,
        learning,
        seed,
        integer(charter, "intervention_cycle"),
        "final-stop-policy-inputs",
        folder,
        output,
        behavior,
        origins,
        Array::makei(references.length(), i => i),
        method,
      )
      records.append(group.records)
      new_records += group.records.length()
      runs.push(
        merge(matched, {
          "method": method.to_json(),
          "seed": seed.to_json(),
          "gradient_route": "stop-policy-inputs",
          "reused_final_evaluation": false,
          "summary": @reference.summarize_tracking(group.trials),
          "trials": group.trials.to_json(),
          "quality": @reference.assess_tracking_quality(group.trials, quality),
          "checkpoint": behavior,
          "final_actor_fit": stopped_fit,
          "final_sampler_sha256": branch_sampler.digest().to_json(),
          "paired_full_sampler_sha256": sampler.digest().to_json(),
          "origin_draws_identical": true,
          "actor_update_state": {
            "file": update_path.to_json(),
            "sha256": update_sha.to_json(),
            "optimizer_sha256": @reference.optimizer_digest(branch_optimizer).to_json(),
            "sampler_sha256": branch_sampler.digest().to_json(),
            "reload_identical": true,
          },
        }),
      )
    }
  }
  ignore(
    @artifacts.save_json(output + "/report.json", {
      "format": "moonrobo.moonbit-reference-final-route-training.v1",
      "config": config,
      "source_study": source.to_json(),
      "source_report_sha256": text(charter, "source_report_sha256").to_json(),
      "diagnostic_study": diagnostic_path.to_json(),
      "diagnostic_source_sha256": text(charter, "diagnostic_report_sha256").to_json(),
      "references": references_path.to_json(),
      "reference_manifest_sha256": field(previous, "reference_manifest_sha256"),
      "quality_target": quality,
      "initial": { "trials": [] },
      "runs": runs.to_json(),
      "reconstruction": checks.to_json(),
      "physical_records": records.to_json(),
      "new_physical_records": new_records.to_json(),
      "reused_physical_records": reused_records.to_json(),
      "provider_seconds": ((@async.now() - started).to_double() / 1000).to_json(),
      "physical_execution_allowed": false,
      "release_qualified": false,
      "scope": field(charter, "scope"),
    }),
  )
}
