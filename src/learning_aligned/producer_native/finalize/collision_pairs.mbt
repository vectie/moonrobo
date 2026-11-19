///|
fn group_pair(a : Int32, b : Int32) -> Bool {
  if a == 0 || b == 0 {
    false
  } else if a > 0 {
    a == b || b < 0
  } else {
    a != b
  }
}

///|
fn pair_code(a : Int32, b : Int32) -> UInt64 {
  let lo = if a < b { a } else { b }
  let hi = if a < b { b } else { a }
  (lo.to_uint64() << 32) | hi.to_uint64()
}

///|
/// Sorted unique explicit exclusion codes, without a lossy Double conversion.
fn filter_codes(pairs : Array[ShapePair], count : Int32) -> Array[UInt64] raise {
  let codes : Array[UInt64] = []
  let seen : Map[UInt64, Unit] = {}
  for pair in pairs {
    guard pair.a >= 0 && pair.b >= 0 && pair.a < count && pair.b < count else {
      fail("shape exclusion index out of bounds")
    }
    let code = pair_code(pair.a, pair.b)
    if !seen.contains(code) {
      seen[code] = ()
      codes.push(code)
    }
  }
  codes.sort()
  codes
}

///|
/// Actual generic pinned ModelBuilder candidate construction. This is the
/// static eligible-pair list, not an AABB/SAP broadphase or actual contacts.
pub fn primitive_candidates(
  shapes : Array[ResolvedShape],
  filters : Array[ShapePair],
  limit : Int32,
) -> Array[ShapePair] raise {
  guard shapes.length() <= 4096 && limit >= 0 && limit <= 1000000 else {
    fail("primitive candidate size/capacity exceeds supported bounds")
  }
  let excluded : Map[UInt64, Unit] = {}
  for code in filter_codes(filters, shapes.length()) {
    excluded[code] = ()
  }
  let indices : Array[(Int32, Int32)] = []
  for i, shape in shapes {
    guard shape.world >= -1 &&
      shape.body >= -1 &&
      shape.flags >= 0 &&
      (shape.flags & 7) == shape.flags else {
      fail("invalid or unsupported primitive candidate ownership/flags")
    }
    if (shape.flags & 2) != 0 {
      indices.push((shape.world, i))
    }
  }
  indices.sort()
  let pairs : Array[ShapePair] = []
  for i in 0..<indices.length() {
    let (_, a) = indices[i]
    let first = shapes[a]
    for j in (i + 1)..<indices.length() {
      let (_, b) = indices[j]
      let second = shapes[b]
      if first.world >= 0 && second.world >= 0 && first.world != second.world {
        break
      }
      if first.body == second.body ||
        (first.body < 0 && second.body < 0) ||
        !group_pair(first.collision_group, second.collision_group) ||
        excluded.contains(pair_code(a, b)) {
        continue
      }
      guard pairs.length() < limit else {
        fail(
          "primitive candidate capacity would overflow; no pairs silently dropped",
        )
      }
      pairs.push(if a < b { { a, b, } } else { { a: b, b: a, } })
    }
  }
  pairs
}

///|
fn shape_world_starts(ids : Array[Int32], worlds : Int32) -> Array[Int32] raise {
  let counts = Array::make(worlds, 0)
  let mut front = 0
  let mut tail = false
  let mut local = false
  let mut previous = 0
  for id in ids {
    guard id >= -1 && id < worlds else {
      fail("shape world index out of range")
    }
    if id == -1 {
      if local {
        tail = true
      } else {
        front += 1
      }
    } else {
      guard !tail && id >= previous else {
        fail("shapes must use contiguous worlds with global prefix/tail")
      }
      previous = id
      local = true
      counts[id] += 1
    }
  }
  let starts = [front]
  for count in counts {
    starts.push(starts.last().unwrap() + count)
  }
  starts.push(ids.length())
  starts
}

///|
fn words64(values : Array[UInt64], kind : String) -> HostArray raise {
  guard (kind == "i64" || kind == "u64") && values.length() <= 2147483647 / 8 else {
    fail("invalid 64-bit typed array")
  }
  let out = []
  for value in values {
    append64(out, value)
  }
  {
    scalar_type: kind,
    shape: [values.length()],
    components: 1,
    bytes: Bytes::from_array(out),
  }
}
