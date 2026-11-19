///|
/// Relative artifact paths use a portable canonical spelling. Symlink/root
/// canonicalization is an observer's task; no string check follows symlinks.
pub fn relative_path(path : String) -> Bool {
  !path.is_empty() &&
  !path.has_prefix("/") &&
  !path.contains("\\") &&
  !path.contains(":") &&
  !path.contains("\u{0}") &&
  path.split("/").all(fn(part) { part != "" && part != "." && part != ".." })
}

///|
pub fn sha256_hex(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(fn(c) { (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') })
}

///|
fn revision_hex(value : String) -> Bool {
  value.length() == 40 &&
  value.iter().all(fn(c) { (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') })
}

///|
/// Both expected and observed hashes are supplied explicitly. Only the
/// caller that actually reads/hashes bytes may attest the observed value.
pub(all) struct BundleFile {
  path : String
  expected_sha256 : String
  observed_sha256 : String
} derive(Debug)

///|
pub(all) enum ModuleBackend {
  PTX
  Cubin
} derive(Debug, Eq)

///|
/// Refers to actual compiler source/binary artifacts in the same inventory.
pub(all) struct ModuleIdentity {
  key : String
  backend : ModuleBackend
  source_path : String
  source_sha256 : String
  binary_path : String
  binary_sha256 : String
  compiler_options : Array[String]
} derive(Debug)

///|
/// canonical_root/imported_source must have been resolved by the integration
/// observer. A true clean flag is never manufactured by this pure validator.
pub(all) struct SourceIdentity {
  name : String
  expected_revision : String
  observed_revision : String
  canonical_root : String
  imported_source : String
  expected_sha256 : String
  observed_sha256 : String
  tracked_clean : Bool
} derive(Debug)

///|
fn canonical_absolute(path : String) -> Bool {
  path.has_prefix("/") &&
  path.length() > 1 &&
  !path.has_suffix("/") &&
  !path.contains("\\") &&
  !path.contains("\u{0}") &&
  path[1:]
  .split("/")
  .all(fn(part) { part != "" && part != "." && part != ".." })
}

///|
pub fn SourceIdentity::validate(
  self : SourceIdentity,
) -> Unit raise ContractError {
  guard !self.name.is_empty() &&
    !self.name.contains("\u{0}") &&
    revision_hex(self.expected_revision) &&
    self.expected_revision == self.observed_revision &&
    self.tracked_clean else {
    raise Invalid(
      "source checkout identity/revision/clean state is not verified",
    )
  }
  guard canonical_absolute(self.canonical_root) &&
    canonical_absolute(self.imported_source) &&
    self.imported_source.has_prefix(self.canonical_root + "/") else {
    raise Invalid(
      "observed SDK source lies outside its canonical verified checkout",
    )
  }
  guard sha256_hex(self.expected_sha256) &&
    self.expected_sha256 == self.observed_sha256 else {
    raise Invalid("observed SDK source bytes differ from expected SHA256")
  }
}

///|
/// Validated compiler/source inventory. Accessor JSON contains supplied facts,
/// never a declaration that SDK execution or graph capture has succeeded.
pub struct ArtifactInventory {
  files : Array[BundleFile]
  modules : Array[ModuleIdentity]
  sources : Array[SourceIdentity]
  graphs : Array[(GraphRole, String)]
}

///|
pub fn validate_inventory(
  files : Array[BundleFile],
  modules : Array[ModuleIdentity],
  sources : Array[SourceIdentity],
  graphs : Array[GraphCapture],
  graph_paths : Map[String, String],
) -> ArtifactInventory raise ContractError {
  guard !files.is_empty() &&
    !sources.is_empty() &&
    graphs.length() == 4 &&
    graph_paths.length() == 4 else {
    raise Invalid("source/files/four-role artifact inventory is incomplete")
  }
  let indexed : Map[String, BundleFile] = Map([])
  for file in files {
    guard relative_path(file.path) &&
      sha256_hex(file.expected_sha256) &&
      file.expected_sha256 == file.observed_sha256 &&
      !indexed.contains(file.path) else {
      raise Invalid(
        "artifact path is invalid/duplicate or observed hash differs",
      )
    }
    indexed[file.path] = file
  }
  let source_names : Array[String] = []
  for source in sources {
    source.validate()
    guard !source_names.contains(source.name) else {
      raise Invalid("source identity duplicated")
    }
    source_names.push(source.name)
  }
  let keys : Array[String] = []
  for item in modules {
    guard !item.key.is_empty() &&
      !item.key.contains("\u{0}") &&
      !keys.contains(item.key) &&
      relative_path(item.source_path) &&
      relative_path(item.binary_path) &&
      item.source_path != item.binary_path else {
      raise Invalid("module identity/key/source/binary paths are invalid")
    }
    guard indexed.get(item.source_path) is Some(source) &&
      source.expected_sha256 == item.source_sha256 &&
      indexed.get(item.binary_path) is Some(binary) &&
      binary.expected_sha256 == item.binary_sha256 else {
      raise Invalid(
        "compiler module source/binary missing from verified file inventory",
      )
    }
    guard item.compiler_options.all(fn(option) {
      !option.is_empty() && !option.contains("\u{0}")
    }) else {
      raise Invalid("compiler options contain invalid metadata")
    }
    guard (match item.backend {
      PTX => item.binary_path.has_suffix(".ptx")
      Cubin => item.binary_path.has_suffix(".cubin")
    }) else {
      raise Invalid("compiler binary path disagrees with actual backend")
    }
    keys.push(item.key)
  }
  let roles : Array[GraphRole] = []
  let used : Array[String] = []
  let paths : Array[String] = []
  let graph_rows : Array[(GraphRole, String)] = []
  for graph in graphs {
    guard !roles.contains(graph.role) else {
      raise Invalid("capture graph role duplicated")
    }
    roles.push(graph.role)
    guard graph_paths.get(graph.role.name()) is Some(path) &&
      relative_path(path) &&
      path.has_suffix(".wrp") &&
      indexed.contains(path) &&
      !paths.contains(path) else {
      raise Invalid("distinct graph artifact absent from verified inventory")
    }
    paths.push(path)
    graph_rows.push((graph.role, path))
    let graph_keys : Array[String] = []
    for key in graph.module_keys {
      guard keys.contains(key) && !graph_keys.contains(key) else {
        raise Invalid("capture module dependency absent or duplicated")
      }
      graph_keys.push(key)
      if !used.contains(key) {
        used.push(key)
      }
    }
  }
  guard used.length() == keys.length() else {
    raise Invalid("compiler module has no declared graph consumer")
  }
  // Snapshot arrays owned by callers to prevent mutation after validation.
  let module_copy = modules.map(fn(item) {
    { ..item, compiler_options: item.compiler_options.copy(), }
  })
  {
    files: files.copy(),
    modules: module_copy,
    sources: sources.copy(),
    graphs: graph_rows,
  }
}

///|
pub fn ArtifactInventory::files_json(self : ArtifactInventory) -> Json {
  self.files
  .map(fn(file) {
    { "path": file.path.to_json(), "sha256": file.observed_sha256.to_json() }
  })
  .to_json()
}

///|
pub fn ArtifactInventory::modules_json(self : ArtifactInventory) -> Json {
  self.modules
  .map(fn(item) {
    {
      "key": item.key.to_json(),
      "backend": (match item.backend {
        PTX => "ptx"
        Cubin => "cubin"
      }).to_json(),
      "source_path": item.source_path.to_json(),
      "source_sha256": item.source_sha256.to_json(),
      "binary_path": item.binary_path.to_json(),
      "binary_sha256": item.binary_sha256.to_json(),
      "compiler_options": item.compiler_options.to_json(),
    }
  })
  .to_json()
}

///|
pub fn ArtifactInventory::sources_json(self : ArtifactInventory) -> Json {
  self.sources
  .map(fn(item) {
    {
      "name": item.name.to_json(),
      "revision": item.observed_revision.to_json(),
      "canonical_root": item.canonical_root.to_json(),
      "imported_source": item.imported_source.to_json(),
      "sha256": item.observed_sha256.to_json(),
    }
  })
  .to_json()
}

///|
pub fn ArtifactInventory::graphs_json(self : ArtifactInventory) -> Json {
  let result : Map[String, Json] = Map([])
  for (role, path) in self.graphs {
    result[role.name()] = path.to_json()
  }
  Json::object(result)
}
