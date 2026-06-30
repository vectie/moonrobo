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
fn source_line_at(lines : Array[String], index : Int) -> String {
  match lines.get(index) {
    Some(line) => line
    None => ""
  }
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
fn numbered_range(
  lines : Array[String],
  start_line : Int,
  end_line : Int,
) -> String {
  if lines.is_empty() {
    ""
  } else {
    let start = max_int(start_line - 1, 0)
    let end = min_int(end_line - 1, lines.length() - 1)
    let rows : Array[String] = []
    for index in start..<=end {
      rows.push("\{index + 1}: \{lines[index]}")
    }
    rows.join("\n")
  }
}

///|
fn collect_line_change_ranges(
  before_lines : Array[String],
  after_lines : Array[String],
) -> Array[(Int, Int, Int, Int)] {
  let ranges : Array[(Int, Int, Int, Int)] = []
  let limit = max_int(before_lines.length(), after_lines.length())
  let mut index = 0
  while index < limit {
    if source_line_at(before_lines, index) == source_line_at(after_lines, index) {
      index += 1
    } else {
      let start = index
      while index < limit &&
            source_line_at(before_lines, index) !=
            source_line_at(after_lines, index) {
        index += 1
      }
      ranges.push(
        (
          start + 1,
          min_int(index, before_lines.length()),
          start + 1,
          min_int(index, after_lines.length()),
        ),
      )
    }
  }
  ranges
}

///|
fn context_range(
  start_line : Int,
  end_line : Int,
  line_count : Int,
  radius : Int,
) -> (Int, Int) {
  if line_count == 0 {
    (0, 0)
  } else {
    (
      max_int(start_line - radius, 1),
      min_int(max_int(end_line + radius, start_line), line_count),
    )
  }
}

///|
fn source_diff_hunks(
  before : String,
  after : String,
) -> Array[UrdfEditorSourceDiffHunk] {
  let before_lines = source_lines(before)
  let after_lines = source_lines(after)
  let ranges = collect_line_change_ranges(before_lines, after_lines)
  let hunks : Array[UrdfEditorSourceDiffHunk] = []
  let context_radius = 2
  for range in ranges {
    let (before_start_raw, before_end_raw, after_start_raw, after_end_raw) = range
    let (before_start, before_end) = context_range(
      before_start_raw,
      before_end_raw,
      before_lines.length(),
      context_radius,
    )
    let (after_start, after_end) = context_range(
      after_start_raw,
      after_end_raw,
      after_lines.length(),
      context_radius,
    )
    hunks.push({
      before_start_line: before_start,
      after_start_line: after_start,
      before_text: numbered_range(before_lines, before_start, before_end),
      after_text: numbered_range(after_lines, after_start, after_end),
    })
  }
  hunks
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
    {
      changed,
      summary: "changed at byte \{first_byte}, line \{before_line}; before \{before.length()} bytes/\{before_lines} lines; after \{after.length()} bytes/\{after_lines} lines",
      before_bytes: before.length(),
      after_bytes: after.length(),
      before_lines,
      after_lines,
      first_changed_byte: first_byte,
      first_changed_line: before_line,
      hunks: source_diff_hunks(before, after),
    }
  }
}

///|
pub fn compare_sources(before : String, after : String) -> UrdfEditorSourceDiff {
  source_diff(before, after)
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
