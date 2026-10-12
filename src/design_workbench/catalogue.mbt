///|
/// A read-only discovery summary. Only a verified draft is selectable; a partial
/// build can still be inspected and forked without repairing its old evidence.
pub(all) struct CatalogueEntry {
  design_id : String
  revision : String
  name : String
  state : String
  design_digest : String
  recorded_at : String
  selectable : Bool
  message : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct DesignCatalogue {
  contract_id : String
  entries : Array[CatalogueEntry]
  limit : Int
  truncated : Bool
  physical_execution_allowed : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn unavailable_entry(
  id : String,
  revision : String,
  state : String,
) -> CatalogueEntry {
  {
    design_id: id,
    revision,
    name: id,
    state,
    design_digest: "",
    recorded_at: "",
    selectable: false,
    message: "Saved evidence is " +
    state +
    "; preserve it and use another revision.",
  }
}

///|
fn catalogue_entry(
  root : String,
  id : String,
  revision : String,
) -> CatalogueEntry {
  if !slug(id) || !slug(revision) {
    return unavailable_entry(id, revision, "invalid-name")
  }
  let path = revision_root(root, id, revision) catch {
    _ => return unavailable_entry(id, revision, "invalid-name")
  }
  if !@fsx.path_exists(path + "/draft.json") {
    return unavailable_entry(id, revision, "missing-draft")
  }
  let view = inspect_revision(root, id, revision) catch {
    _ => return unavailable_entry(id, revision, "corrupt-or-unreadable-draft")
  }
  guard view is { "draft": json, "state": String(state), .. } else {
    return unavailable_entry(id, revision, "corrupt-or-unreadable-draft")
  }
  let draft : DesignDraft = decode(json.stringify()) catch {
    _ => return unavailable_entry(id, revision, "corrupt-or-unreadable-draft")
  }
  let design : Json = decode(draft.design_text) catch {
    _ => return unavailable_entry(id, revision, "corrupt-or-unreadable-draft")
  }
  let name = match design {
    { "mission": { "name": String(name), .. }, .. } => name
    _ => id
  }
  {
    design_id: id,
    revision,
    name,
    state,
    design_digest: draft.design_digest,
    recorded_at: draft.recorded_at,
    selectable: true,
    message: if state == "unconfirmed" {
      "Partial, missing or changed build evidence. Verified draft can be inspected or forked; export is blocked."
    } else {
      ""
    },
  }
}

///|
/// List at most 40 saved revision summaries in lexical order, without creating
/// directories, writing receipts, repairing evidence or choosing an active book.
/// At most 40 design directories and 40 revisions per design are considered.
/// Directory names are listed before this bound; this is not a streaming index.
pub fn catalogue(root : String) -> DesignCatalogue raise WorkbenchError {
  let path = root + "/.moonsuite/products/moonrobo/design-workbench"
  let entries : Array[CatalogueEntry] = []
  let mut truncated = false
  if @fsx.path_exists(path) {
    let names = @fsx.read_dir(path).to_owned() catch {
      _ => raise WorkbenchError("Saved design library cannot be read")
    }
    names.sort()
    truncated = names.length() > 40
    for id in names[:40] {
      if entries.length() >= 40 {
        truncated = true
        break
      }
      if !slug(id) {
        entries.push(unavailable_entry(id, "", "invalid-name"))
        continue
      }
      let revisions = @fsx.read_dir(path + "/" + id).to_owned() catch {
        _ => {
          entries.push(unavailable_entry(id, "", "unreadable-design"))
          continue
        }
      }
      revisions.sort()
      if revisions.length() > 40 {
        truncated = true
      }
      for revision in revisions[:40] {
        if entries.length() >= 40 {
          truncated = true
          break
        }
        entries.push(catalogue_entry(root, id, revision))
      }
    }
  }
  {
    contract_id: "moonrobo.design-catalogue.v1",
    entries,
    limit: 40,
    truncated,
    physical_execution_allowed: false,
  }
}
