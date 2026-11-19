///|
/// Offline authoring is explicit, never invoked by static checks or replay.
/// `export` retains its original semantics for immutable historical wrappers.
async fn main {
  let args = @env.args()
  match args {
    [_, "diagnose-sdk", config, tape, manifest, output] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      let result = @producer.trace_sdk(
        config,
        tape,
        manifest,
        output,
        diagnostic=true,
      )
      println(result.stringify(indent=2))
      guard result is { "success": true, .. } else {
        fail("SDK diagnostic failed; see preserved report")
      }
    }
    [_, "trace-sdk", config, tape, manifest, output] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @producer.trace_sdk(config, tape, manifest, output).stringify(indent=2),
      )
    }
    [_, "export" | "export-reference", config] => {
      let config : @producer.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@producer.export_bundle(config).stringify(indent=2))
    }
    [_, "export-native-io", config] => {
      let config : @hybrid.ExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@hybrid.export_bundle(config).stringify(indent=2))
    }
    [_, "export-native-schedule", config] => {
      let config : @hybrid.ScheduledExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@hybrid.export_scheduled_bundle(config).stringify(indent=2))
    }
    [_, "export-native-physics-host", config] => {
      let config : @hybrid.ScheduledExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@hybrid.export_physics_host_bundle(config).stringify(indent=2))
    }
    [_, "export-native-constants-host", config] => {
      let config : @hybrid.ScheduledExportConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@hybrid.export_constants_host_bundle(config).stringify(indent=2))
    }
    [_, "prepare-finalize", config] => {
      let config : @native.FinalizeRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_finalize(config).stringify(indent=2))
    }
    [_, "prepare-collision-finalize", config] => {
      let config : @native.CollisionFinalizeRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_collision_finalize(config).stringify(indent=2))
    }
    [_, "prepare-factorization", config] => {
      let config : @native.FactorizationRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_factorization(config).stringify(indent=2))
    }
    [_, "prepare-convergence", config] => {
      let config : @native.ConvergenceRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_convergence(config).stringify(indent=2))
    }
    [_, "prepare-set-constants", config] => {
      let config : @native.SetConstantsRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_set_constants(config).stringify(indent=2))
    }
    [_, "prepare-scene", config] => {
      let config : @native.SceneRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_scene(config).stringify(indent=2))
    }
    [_, "prepare-builder", config] => {
      let config : @native.BuilderRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_builder(config).stringify(indent=2))
    }
    [_, "prepare-constants", config] => {
      let config : @native.ConstantsRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_constants(config).stringify(indent=2))
    }
    [_, "prepare-mass-layout", config] => {
      let config : @native.MassLayoutRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_mass_layout(config).stringify(indent=2))
    }
    [_, "prepare-model", config] => {
      let config : @native.ModelRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@native.prepare_model(config).stringify(indent=2))
    }
    [_, "compile-cuda", config] => {
      let config : @compiler.ArtifactRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@compiler.compile_artifact(config).stringify(indent=2))
    }
    [_, "compile-kernels", config] => {
      let config : @kernels.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@kernels.compile_specialization(config).stringify(indent=2))
    }
    [_, "compile-physics-kernels", config] => {
      let config : @physics_kernels.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @physics_kernels.compile_specialization(config).stringify(indent=2),
      )
    }
    [_, "compile-narrowphase", config] => {
      let config : @narrowphase.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@narrowphase.compile_specialization(config).stringify(indent=2))
    }
    [_, "capture-kernel", config] => {
      let config : @capture.CaptureConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@capture.capture(config).stringify(indent=2))
    }
    [_, "collide-native", config] => {
      let config : @collision_native.Config = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@collision_native.run(config).stringify(indent=2))
    }
    [_, "run-gpu-pipeline", config] => {
      let config = @gpu_pipeline.decode_config(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@gpu_pipeline.execute(config).stringify(indent=2))
    }
    [_, "prepare-mesh", config] => {
      let (request, output) = @schema_constraints.decode_artifact(
        @json.parse(@fs.read_file(config).text()),
      )
      let request : @cooking.MeshRequest = @json.from_json(request)
      println(@cooking.mesh_artifact(request, output).stringify(indent=2))
    }
    [_, "cook-host-mesh", config] => {
      let request : @cooking.ExecuteRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@cooking.execute_cook(request).stringify(indent=2))
    }
    [_, "cook-native-geometry", config] => {
      let (request, output) = @schema_constraints.decode_artifact(
        @json.parse(@fs.read_file(config).text()),
      )
      let request = @cooking.decode_geometry_request(request)
      println(@cooking.geometry_artifact(request, output).stringify(indent=2))
    }
    [_, "prepare-schema", config] => {
      let (request, output) = @schema_constraints.decode_artifact(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @schema_constraints.schema_artifact(
          @schema_constraints.decode_schema(request),
          output,
        ).stringify(indent=2),
      )
    }
    [_, "prepare-equalities", config] => {
      let (request, output) = @schema_constraints.decode_artifact(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @schema_constraints.equality_artifact(
          @schema_constraints.decode_equalities(request),
          output,
        ).stringify(indent=2),
      )
    }
    [_, "compile-convex-gjk", config] => {
      let request : @convex.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@convex.compile_specialization(request).stringify(indent=2))
    }
    [_, "compile-mathdx-tile", config] => {
      let request = @tile_solver.decode_config(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@tile_solver.compile_artifact(request).stringify(indent=2))
    }
    [_, "compile-device-convergence", config] => {
      let request : @device_convergence.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @device_convergence.compile_specialization(request).stringify(indent=2),
      )
    }
    [_, "compile-convex-contacts", config] => {
      let request : @convex_contacts.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @convex_contacts.compile_specialization(request).stringify(indent=2),
      )
    }
    [_, "compile-sparse-solver", config] => {
      let request = @sparse_solver.decode_config(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@sparse_solver.compile_artifact(request).stringify(indent=2))
    }
    [_, "compile-sparse-lu", config] => {
      let request = @sparse_solver.decode_lu_config(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@sparse_solver.compile_lu_artifact(request).stringify(indent=2))
    }
    [_, "compile-newton-solver", config] => {
      let request : @newton_solver.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @newton_solver.compile_specialization(request).stringify(indent=2),
      )
    }
    [_, "compile-solver-metrics", config] => {
      let request = @solver_metrics.decode_config(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@solver_metrics.compile_artifact(request).stringify(indent=2))
    }
    [_, "prepare-solver-preconditioner", config] => {
      let request : @solver_metrics.PreconditionerPlan = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @solver_metrics.preconditioner_plan(request)
        .to_json()
        .stringify(indent=2),
      )
    }
    [_, "prepare-solver-backbone", config] => {
      let value = @json.parse(@fs.read_file(config).text())
      guard value is { "request": request, "include_fluid": include_fluid, .. } else {
        fail("backbone plan requires request and include_fluid")
      }
      let request : @solver_metrics.PreconditionerPlan = @json.from_json(
        request,
      )
      let include_fluid : Bool = @json.from_json(include_fluid)
      println(
        @solver_metrics.backbone_factor_plan(request, include_fluid~)
        .to_json()
        .stringify(indent=2),
      )
    }
    [_, "compile-solver-adapters", config] => {
      let request : @solver_adapters.CompileConfig = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @solver_adapters.compile_specialization(request).stringify(indent=2),
      )
    }
    [_, "prepare-compact-smooth", config] => {
      let request : @solver_adapters.CompactPlan = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @solver_adapters.compact_smooth_plan(request)
        .to_json()
        .stringify(indent=2),
      )
    }
    [_, "prepare-compact-constraints", config] => {
      let request : @solver_adapters.CompactPlan = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(
        @solver_adapters.compact_constraint_plan(request)
        .to_json()
        .stringify(indent=2),
      )
    }
    [_, "prepare-incremental-newton", config] => {
      let request : @solver_adapters.IncrementalPlan = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@solver_adapters.incremental_plan(request).stringify(indent=2))
    }
    [_, "prepare-effective-cg", config] => {
      let request : @solver_adapters.EffectiveCGPlan = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@solver_adapters.effective_cg_plan(request).stringify(indent=2))
    }
    [_, "prepare-newton-program", config] => {
      let request : @newton_solver.PlanRequest = @json.from_json(
        @json.parse(@fs.read_file(config).text()),
      )
      println(@newton_solver.plan(request).stringify(indent=2))
    }
    [_, "prepare-newton-operator-program", config] => {
      let value = @json.parse(@fs.read_file(config).text())
      guard value
        is { "request": request, "preconditioner_program": Array(program), .. } else {
        fail("operator program requires request and preconditioner_program")
      }
      let request : @newton_solver.PlanRequest = @json.from_json(request)
      println(
        @newton_solver.plan_with_preconditioner(request, program).stringify(
          indent=2,
        ),
      )
    }
    _ =>
      fail(
        "usage: reference_apic_export {export-native-io|export-native-schedule|export-native-physics-host|export-native-constants-host|export-reference|prepare-model|prepare-scene|prepare-builder|prepare-finalize|prepare-collision-finalize|prepare-constants|prepare-mass-layout|prepare-factorization|prepare-convergence|prepare-set-constants|prepare-mesh|cook-host-mesh|cook-native-geometry|prepare-schema|prepare-equalities|compile-cuda|compile-kernels|compile-physics-kernels|compile-narrowphase|compile-convex-gjk|compile-convex-contacts|compile-mathdx-tile|compile-sparse-solver|compile-sparse-lu|compile-device-convergence|compile-newton-solver|prepare-newton-program|prepare-newton-operator-program|compile-solver-metrics|prepare-solver-preconditioner|prepare-solver-backbone|compile-solver-adapters|prepare-compact-smooth|prepare-compact-constraints|prepare-incremental-newton|prepare-effective-cg|capture-kernel|collide-native|run-gpu-pipeline} CONFIG.json; export is the preserved reference alias; no command is run by static checks",
      )
  }
}
