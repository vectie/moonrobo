///|
fn native_source(name : String) -> String raise {
  match name {
    "reference_initialization.py" =>
      "src/learning_reference/reference_initialization_study.mbt"
    "reference_actor.py" => "src/learning_reference/reference_actor.mbt"
    "reference_learning.py" => "src/learning_reference/reference_learning.mbt"
    "reference_task.py" => "src/learning_reference/reference_task.mbt"
    "reference_learning_study.py" =>
      "src/learning_reference/reference_learning_study.mbt"
    "reference_last_cycle.py" =>
      "src/learning_reference/reference_last_cycle_study.mbt"
    "full_body_reference.py" => "src/learning_balance/physics/reference.mbt"
    "full_body_reference_study.py" =>
      "src/learning_balance/reference_study/run.mbt"
    "reference_root_integration.py" =>
      "src/learning_reference_roots/integration.mbt"
    "reference_final_route_training.py" =>
      "src/learning_reference_routes/final.mbt"
    "reference_gradient_route.py" =>
      "src/learning_reference_routes/gradient.mbt"
    "reference_action_response.py" =>
      "src/learning_reference_directions/action.mbt"
    "reference_feedback_response.py" =>
      "src/learning_reference_directions/feedback.mbt"
    "reference_tail_directions.py" => "src/learning_reference_routes/tail.mbt"
    "reference_initialization_export.py" =>
      "src/learning_reference/reference_initialization_export.mbt"
    "reference_learning_export.py"
    | "reference_learning_export-final-verify.py" =>
      "src/learning_reference/reference_learning_export.mbt"
    "reference_feedback_response_export.py" =>
      "src/learning_reference_directions/export.mbt"
    "reference_root_export.py" => "src/learning_reference_roots/export.mbt"
    _ => fail("missing native source mapping: " + name)
  }
}

///|
async fn copy_tree(
  root : String,
  relative : String,
  destination : String,
  entries : Map[String, String],
) -> Unit {
  let folder = destination + "/" + relative
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  for name in @fs.readdir(root + "/" + relative, sort=true) {
    let path = relative + "/" + name
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => copy_tree(root, path, destination, entries)
      Regular =>
        if name.has_suffix(".mbt") ||
          name.has_suffix(".c") ||
          name.has_suffix(".h") ||
          name.has_suffix(".cpp") ||
          name.has_suffix(".hpp") ||
          name == "moon.pkg" ||
          name == "moon.mod" {
          if name.has_suffix("_test.mbt") || name.has_suffix("_wbtest.mbt") {
            continue
          }
          let bytes = @fs.read_file(root + "/" + path).binary()
          @fs.write_file(
            destination + "/" + path,
            bytes,
            create_mode=CreateOrTruncate,
          )
          entries[path] = @artifacts.sha256(bytes)
        }
      _ => ()
    }
  }
}

///|
async fn archive_sources(root : String, output : String) -> Unit {
  let entries : Map[String, String] = {}
  let destination = output + "/native-provider-sources"
  for
    name in [
      "learning_reference", "learning_reference_routes", "learning_reference_roots",
      "learning_reference_directions", "learning_reference_adapters", "learning_balance",
      "learning_physics", "learning_numeric", "learning_training", "learning_artifacts",
      "learning_torch_rng",
    ] {
    copy_tree(root, "src/" + name, destination, entries)
  }
  copy_tree(root, "cmd/reference_scripts", destination, entries)
  // Canonical numeric and physics libraries are workspace dependencies. Their
  // complete source trees are archived too, rather than hashing reexports alone.
  for name in ["moonnum", "moonphys"] {
    let sibling = root + "/../" + name
    if @fs.exists(sibling + "/moon.mod") {
      let library_entries : Map[String, String] = {}
      // Do not walk build/dependency caches; canonical package sources live at
      // the root and in explicitly source-bearing subdirectories.
      archive_dependency(
        sibling,
        "",
        destination + "/workspace/" + name,
        library_entries,
      )
      for path, digest in library_entries {
        entries["workspace/" + name + "/" + path] = digest
      }
    }
  }
  ignore(
    @artifacts.save_json(output + "/native-sources.json", {
      "format": "moonrobo.native-reference-source-archive.v1",
      "files": Json(entries),
      "backend": "moonbit-native",
      "legacy_python_sources_are_executed": false,
    }),
  )
}

///|
async fn archive_dependency(
  root : String,
  relative : String,
  destination : String,
  entries : Map[String, String],
) -> Unit {
  let folder = destination + "/" + relative
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true)
  }
  for name in @fs.readdir(root + "/" + relative, sort=true) {
    if ["_build", "target", ".git", ".mooncakes", "node_modules", ".repos"].contains(
        name,
      ) {
      continue
    }
    let path = if relative == "" { name } else { relative + "/" + name }
    match @fs.kind(root + "/" + path, follow_symlink=false) {
      Directory => archive_dependency(root, path, destination, entries)
      Regular =>
        if name.has_suffix(".mbt") ||
          name.has_suffix(".c") ||
          name.has_suffix(".h") ||
          name == "moon.mod" ||
          name == "moon.pkg" {
          if name.has_suffix("_test.mbt") || name.has_suffix("_wbtest.mbt") {
            continue
          }
          let bytes = @fs.read_file(root + "/" + path).binary()
          @fs.write_file(
            destination + "/" + path,
            bytes,
            create_mode=CreateOrTruncate,
          )
          entries[path] = @artifacts.sha256(bytes)
        }
      _ => ()
    }
  }
}

///|
async fn annotate_report(
  root : String,
  output : String,
  entry : String,
) -> Unit {
  let report = @reference.json_fields(
    @artifacts.load_json(output + "/report.json"),
  )
  let fields : Array[(String, String)] = match entry {
    "reference_initialization.py" =>
      [
        ("actor_provider_sha256", "reference_actor.py"),
        ("harness_sha256", "full_body_reference.py"),
      ]
    "reference_learning_study.py" =>
      [
        ("learning_provider_sha256", "reference_learning.py"),
        ("task_provider_sha256", "reference_task.py"),
        ("actor_provider_sha256", "reference_actor.py"),
      ]
    "reference_tail_directions.py" => [("provider_sha256", entry)]
    _ => []
  }
  for (key, name) in fields {
    report[key] = Json(
      @reference.source_digest(root + "/" + native_source(name)),
    )
  }
  report["runtime_backend"] = "moonbit-native".to_json()
  let provider = native_source(entry)
  let provider_hash = @reference.source_digest(root + "/" + provider)
  if report.get("provider_sha256") is Some(String(existing)) {
    guard existing == provider_hash else {
      fail("native report provider identity changed")
    }
  }
  report["provider_source"] = Json(provider)
  report["provider_sha256"] = Json(provider_hash)
  report["source_language"] = "moonbit".to_json()
  report["native_sources_sha256"] = Json(
    @reference.source_digest(output + "/native-sources.json"),
  )
  report["native_sources"] = "native-sources.json".to_json()
  report["legacy_python_backend_used"] = false.to_json()
  ignore(@artifacts.save_json(output + "/report.json", Json(report)))
}
