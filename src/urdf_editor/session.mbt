///|
let default_session_history_limit = 50

///|
pub(all) struct UrdfEditorSessionSnapshot {
  source : String
  selected_node_id : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorSession {
  baseline_source : String
  source : String
  selected_node_id : String
  past : Array[UrdfEditorSessionSnapshot]
  future : Array[UrdfEditorSessionSnapshot]
  latest_edit : UrdfEditResult?
  dirty : Bool
  diff : UrdfEditorSourceDiff
  history : Array[UrdfEditorHistoryEntry]
  past_count : Int
  future_count : Int
  can_undo : Bool
  can_redo : Bool
} derive(Debug, Eq, ToJson, FromJson)

///|
fn session_snapshot(session : UrdfEditorSession) -> UrdfEditorSessionSnapshot {
  { source: session.source, selected_node_id: session.selected_node_id }
}

///|
fn make_session(
  baseline_source : String,
  source : String,
  selected_node_id : String,
  past : Array[UrdfEditorSessionSnapshot],
  future : Array[UrdfEditorSessionSnapshot],
  latest_edit : UrdfEditResult?,
) -> UrdfEditorSession {
  let normalized_selection = normalize_session_selection(
    source, selected_node_id,
  )
  {
    baseline_source,
    source,
    selected_node_id: normalized_selection,
    past,
    future,
    latest_edit,
    dirty: source != baseline_source,
    diff: source_diff(baseline_source, source),
    history: session_history_entries(
      baseline_source, source, normalized_selection, past, future,
    ),
    past_count: past.length(),
    future_count: future.length(),
    can_undo: !past.is_empty(),
    can_redo: !future.is_empty(),
  }
}

///|
fn normalize_session_selection(
  source : String,
  selected_node_id : String,
) -> String {
  let candidate = if selected_node_id.trim() == "" {
    "robot"
  } else {
    selected_node_id
  }
  if candidate == "robot" {
    "robot"
  } else {
    let doc = parse_document(source)
    match select_component(doc, candidate) {
      Some(_) => candidate
      None => "robot"
    }
  }
}

///|
fn append_bounded_snapshot(
  snapshots : Array[UrdfEditorSessionSnapshot],
  next : UrdfEditorSessionSnapshot,
  limit : Int,
) -> Array[UrdfEditorSessionSnapshot] {
  let bounded : Array[UrdfEditorSessionSnapshot] = []
  let total = snapshots.length() + 1
  let start = if total > limit { total - limit } else { 0 }
  for index in start..<snapshots.length() {
    bounded.push(snapshots[index])
  }
  bounded.push(next)
  bounded
}

///|
fn snapshots_without_last(
  snapshots : Array[UrdfEditorSessionSnapshot],
) -> Array[UrdfEditorSessionSnapshot] {
  let next : Array[UrdfEditorSessionSnapshot] = []
  if !snapshots.is_empty() {
    for index in 0..<(snapshots.length() - 1) {
      next.push(snapshots[index])
    }
  }
  next
}

///|
fn prepend_snapshot(
  snapshot : UrdfEditorSessionSnapshot,
  snapshots : Array[UrdfEditorSessionSnapshot],
) -> Array[UrdfEditorSessionSnapshot] {
  let next : Array[UrdfEditorSessionSnapshot] = [snapshot]
  for item in snapshots {
    next.push(item)
  }
  next
}

///|
fn snapshots_without_first(
  snapshots : Array[UrdfEditorSessionSnapshot],
) -> Array[UrdfEditorSessionSnapshot] {
  let next : Array[UrdfEditorSessionSnapshot] = []
  for index in 1..<snapshots.length() {
    next.push(snapshots[index])
  }
  next
}

///|
fn retarget_selection_after_edit(
  edit : UrdfEditResult,
  fallback : String,
) -> String {
  match edit.target.find("->") {
    Some(offset) => {
      let new_name = edit.target[offset + 2:]
      match edit.command {
        "rename-link" => "link:\{new_name}"
        "rename-joint" => "joint:\{new_name}"
        _ => fallback
      }
    }
    None =>
      match edit.command {
        "add-link" => "link:\{edit.target}"
        "add-joint" => "joint:\{edit.target}"
        "add-visual" => "visual:\{edit.target}"
        "add-collision" => "collision:\{edit.target}"
        "remove-visual" | "remove-collision" => "robot"
        _ => fallback
      }
  }
}

///|
pub fn start_session(
  source : String,
  selected_node_id? : String = "robot",
) -> UrdfEditorSession {
  make_session(source, source, selected_node_id, [], [], None)
}

///|
pub fn session_document(session : UrdfEditorSession) -> UrdfDocument {
  parse_document(session.source)
}

///|
pub fn select_session_component(
  session : UrdfEditorSession,
  node_id : String,
) -> UrdfEditorSession {
  make_session(
    session.baseline_source,
    session.source,
    node_id,
    session.past,
    session.future,
    session.latest_edit,
  )
}

///|
pub fn push_session_edit(
  session : UrdfEditorSession,
  edit : UrdfEditResult,
  selected_node_id? : String = "",
) -> UrdfEditorSession {
  let next_selected = if selected_node_id.trim() == "" {
    retarget_selection_after_edit(edit, session.selected_node_id)
  } else {
    selected_node_id
  }
  if !edit.changed {
    make_session(
      session.baseline_source,
      session.source,
      next_selected,
      session.past,
      session.future,
      Some(edit),
    )
  } else {
    make_session(
      session.baseline_source,
      edit.source,
      next_selected,
      append_bounded_snapshot(
        session.past,
        session_snapshot(session),
        default_session_history_limit,
      ),
      [],
      Some(edit),
    )
  }
}

///|
pub fn undo_session(session : UrdfEditorSession) -> UrdfEditorSession? {
  if session.past.is_empty() {
    None
  } else {
    let previous = session.past[session.past.length() - 1]
    Some(
      make_session(
        session.baseline_source,
        previous.source,
        previous.selected_node_id,
        snapshots_without_last(session.past),
        prepend_snapshot(session_snapshot(session), session.future),
        None,
      ),
    )
  }
}

///|
pub fn redo_session(session : UrdfEditorSession) -> UrdfEditorSession? {
  match session.future.get(0) {
    Some(next_snapshot) =>
      Some(
        make_session(
          session.baseline_source,
          next_snapshot.source,
          next_snapshot.selected_node_id,
          append_bounded_snapshot(
            session.past,
            session_snapshot(session),
            default_session_history_limit,
          ),
          snapshots_without_first(session.future),
          None,
        ),
      )
    None => None
  }
}

///|
pub fn commit_session(session : UrdfEditorSession) -> UrdfEditorSession {
  make_session(
    session.source,
    session.source,
    session.selected_node_id,
    session.past,
    session.future,
    session.latest_edit,
  )
}
