///|
pub suberror WorkbenchError {
  WorkbenchError(String)
} derive(Debug)

///|
pub(all) struct DesignDraft {
  contract_id : String
  design_id : String
  revision : String
  design_text : String
  design_digest : String
  recorded_at : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn require(value : Bool, message : String) -> Unit raise WorkbenchError {
  if !value {
    raise WorkbenchError(message)
  }
}

///|
fn slug(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 64 &&
  value
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
  })
}

///|
fn read(path : String) -> String raise WorkbenchError {
  @fsx.read_file_to_string(path) catch {
    _ => raise WorkbenchError("Cannot read " + path)
  }
}

///|
fn write(path : String, text : String) -> Unit raise WorkbenchError {
  @fsx.write_string_to_file(path, text) catch {
    _ =>
      raise WorkbenchError(
        "Cannot write " +
        path +
        "; preserve partial evidence and use a new revision",
      )
  }
}

///|
fn[T : @json.FromJson] decode(text : String) -> T raise WorkbenchError {
  @json.from_json(@json.parse(text)) catch {
    _ => raise WorkbenchError("Invalid workbench JSON")
  }
}

///|
fn directory(path : String) -> Unit raise WorkbenchError {
  if !@fsx.path_exists(path) {
    @fsx.create_dir(path) catch {
      _ =>
        if !@fsx.path_exists(path) {
          raise WorkbenchError("Cannot create " + path)
        }
    }
  }
}

///|
fn revision_root(
  root : String,
  id : String,
  revision : String,
) -> String raise WorkbenchError {
  require(
    slug(id) && slug(revision),
    "Design ID and revision must be lowercase slugs of at most 64 characters",
  )
  root + "/.moonsuite/products/moonrobo/design-workbench/" + id + "/" + revision
}

///|
fn prepare_parent(root : String, id : String) -> Unit raise WorkbenchError {
  require(
    @fsx.path_exists(root),
    "The selected workspace root must already exist",
  )
  let mut path = root
  for segment in [".moonsuite", "products", "moonrobo", "design-workbench", id] {
    path += "/" + segment
    directory(path)
  }
}

///|
fn check_design(design : Json) -> (String, String) raise WorkbenchError {
  guard design
    is {
      "design_id": String(id),
      "revision": String(revision),
      "mission": { "robot_class": String("excavation-haul-rover"), .. },
      "task_loop": Array(steps),
      "mechanisms": Array(mechanisms),
      "validation": { "scenarios": Array(scenarios), .. },
      "constraints": {
        "commanded_speed_mps": {
          "min": Number(min, ..),
          "max": Number(max, ..),
          ..
        },
        ..
      },
      ..
    } else {
    raise WorkbenchError(
      "This workbench supports excavation-haul-rover designs with task loops, mechanisms, scenarios and minimum/maximum speed in m/s",
    )
  }
  require(
    slug(id) && slug(revision),
    "Design ID and revision must be lowercase slugs of at most 64 characters",
  )
  require(
    steps.length() <= 24 &&
    mechanisms.length() <= 12 &&
    scenarios.length() <= 12,
    "Use at most 24 loop steps, 12 mechanisms and 12 validation scenarios",
  )
  require(
    min > 0.0 && max >= min && max <= 0.5,
    "Workbench speed limits require 0 < minimum <= maximum <= 0.5 m/s",
  )
  match @design_builder.profile_from_design(design) {
    Err(error) => raise WorkbenchError(error.field + ": " + error.message)
    Ok(_) => ()
  }
  (id, revision)
}

///|
/// Persist a new immutable draft revision. Editing means saving a new revision;
/// duplicate exact saves return the existing draft without changing timestamps.
pub fn save_draft(
  root : String,
  design : Json,
  recorded_at : String,
) -> DesignDraft raise WorkbenchError {
  let (id, revision) = check_design(design)
  require(
    recorded_at.length() >= 20 &&
    recorded_at.contains("T") &&
    recorded_at.has_suffix("Z"),
    "recorded_at must be a UTC timestamp",
  )
  let path = revision_root(root, id, revision)
  let text = design.stringify(indent=2) + "\n"
  if @fsx.path_exists(path) {
    let existing = load_draft(root, id, revision)
    require(
      existing.design_text == text,
      "This revision already contains another draft; choose a new revision",
    )
    return existing
  }
  prepare_parent(root, id)
  // Atomic directory reservation: a second writer never replaces the draft.
  @fsx.create_dir(path) catch {
    _ =>
      raise WorkbenchError(
        "Revision was reserved by another save; re-open it before continuing",
      )
  }
  let draft : DesignDraft = {
    contract_id: "moonrobo.design-draft.v1",
    design_id: id,
    revision,
    design_text: text,
    design_digest: @moondata_core.text_checksum(text),
    recorded_at,
  }
  write(path + "/draft.json", draft.to_json().stringify(indent=2) + "\n")
  draft
}

///|
pub fn load_draft(
  root : String,
  id : String,
  revision : String,
) -> DesignDraft raise WorkbenchError {
  let path = revision_root(root, id, revision)
  let draft : DesignDraft = decode(read(path + "/draft.json"))
  require(
    draft.contract_id == "moonrobo.design-draft.v1" &&
    draft.design_id == id &&
    draft.revision == revision,
    "Draft identity mismatch",
  )
  require(
    draft.design_digest == @moondata_core.text_checksum(draft.design_text),
    "Draft digest mismatch",
  )
  let (checked_id, checked_revision) = check_design(decode(draft.design_text))
  require(
    checked_id == id && checked_revision == revision,
    "Draft source identity mismatch",
  )
  draft
}
