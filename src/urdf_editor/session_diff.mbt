///|
pub(all) struct UrdfEditorSourceDiffHunk {
  before_start_line : Int
  after_start_line : Int
  before_text : String
  after_text : String
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorSourceDiff {
  changed : Bool
  summary : String
  before_bytes : Int
  after_bytes : Int
  before_lines : Int
  after_lines : Int
  first_changed_byte : Int
  first_changed_line : Int
  hunks : Array[UrdfEditorSourceDiffHunk]
} derive(Debug, Eq, ToJson, FromJson)

///|
pub(all) struct UrdfEditorHistoryEntry {
  lane : String
  index : Int
  current : Bool
  selected_node_id : String
  byte_count : Int
  line_count : Int
  changed_from_baseline : Bool
  diff_summary : String
} derive(Debug, Eq, ToJson, FromJson)

///|
fn source_lines(source : String) -> Array[String] {
  let lines : Array[String] = []
  for line in source.split("\n") {
    lines.push(line.to_owned())
  }
  lines
}

///|
fn editor_source_line_count(source : String) -> Int {
  if source == "" {
    0
  } else {
    source_lines(source).length()
  }
}

///|
fn first_diff_byte(before : String, after : String) -> Int {
  let limit = if before.length() < after.length() {
    before.length()
  } else {
    after.length()
  }
  for index in 0..<limit {
    if before[index:index + 1] != after[index:index + 1] {
      return index
    }
  }
  limit
}

///|
fn line_number_at_byte(source : String, byte_index : Int) -> Int {
  let limit = if byte_index < source.length() {
    byte_index
  } else {
    source.length()
  }
  let mut line = 1
  for index in 0..<limit {
    if source[index:index + 1] == "\n" {
      line += 1
    }
  }
  line
}

///|
fn min_int(left : Int, right : Int) -> Int {
  if left < right {
    left
  } else {
    right
  }
}

///|
fn max_int(left : Int, right : Int) -> Int {
  if left > right {
    left
  } else {
    right
  }
}

///|
fn numbered_context(lines : Array[String], center_line : Int) -> String {
  if lines.is_empty() {
    ""
  } else {
    let center_index = max_int(center_line - 1, 0)
    let start = max_int(center_index - 2, 0)
    let end = min_int(center_index + 2, lines.length() - 1)
    let rows : Array[String] = []
    for index in start..<=end {
      rows.push("\{index + 1}: \{lines[index]}")
    }
    rows.join("\n")
  }
}

///|
fn source_diff(before : String, after : String) -> UrdfEditorSourceDiff {
  let changed = before != after
  let before_lines = editor_source_line_count(before)
  let after_lines = editor_source_line_count(after)
  if !changed {
    {
      changed,
      summary: "unchanged; \{before.length()} bytes; \{before_lines} lines",
      before_bytes: before.length(),
      after_bytes: after.length(),
      before_lines,
      after_lines,
      first_changed_byte: before.length(),
      first_changed_line: before_lines,
      hunks: [],
    }
  } else {
    let first_byte = first_diff_byte(before, after)
    let before_line = line_number_at_byte(before, first_byte)
    let after_line = line_number_at_byte(after, first_byte)
    let before_context = numbered_context(source_lines(before), before_line)
    let after_context = numbered_context(source_lines(after), after_line)
    {
      changed,
      summary: "changed at byte \{first_byte}, line \{before_line}; before \{before.length()} bytes/\{before_lines} lines; after \{after.length()} bytes/\{after_lines} lines",
      before_bytes: before.length(),
      after_bytes: after.length(),
      before_lines,
      after_lines,
      first_changed_byte: first_byte,
      first_changed_line: before_line,
      hunks: [
        {
          before_start_line: max_int(before_line - 2, 1),
          after_start_line: max_int(after_line - 2, 1),
          before_text: before_context,
          after_text: after_context,
        },
      ],
    }
  }
}

///|
fn history_entry(
  baseline_source : String,
  lane : String,
  index : Int,
  current : Bool,
  snapshot : UrdfEditorSessionSnapshot,
) -> UrdfEditorHistoryEntry {
  let diff = source_diff(baseline_source, snapshot.source)
  {
    lane,
    index,
    current,
    selected_node_id: snapshot.selected_node_id,
    byte_count: snapshot.source.length(),
    line_count: editor_source_line_count(snapshot.source),
    changed_from_baseline: diff.changed,
    diff_summary: diff.summary,
  }
}

///|
fn session_history_entries(
  baseline_source : String,
  source : String,
  selected_node_id : String,
  past : Array[UrdfEditorSessionSnapshot],
  future : Array[UrdfEditorSessionSnapshot],
) -> Array[UrdfEditorHistoryEntry] {
  let entries : Array[UrdfEditorHistoryEntry] = []
  for index in 0..<past.length() {
    entries.push(
      history_entry(baseline_source, "past", index, false, past[index]),
    )
  }
  entries.push(
    history_entry(baseline_source, "present", past.length(), true, {
      source,
      selected_node_id,
    }),
  )
  for index in 0..<future.length() {
    entries.push(
      history_entry(baseline_source, "future", index, false, future[index]),
    )
  }
  entries
}
