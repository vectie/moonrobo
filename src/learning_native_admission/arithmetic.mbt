///|
const GiB : Int64 = 1073741824L

///|
fn add(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && a <= 9223372036854775807L - b else {
    fail("native admission sum is negative or overflows Int64")
  }
  a + b
}

///|
fn mul(a : Int64, b : Int64) -> Int64 raise {
  guard a >= 0L && b >= 0L && (b == 0L || a <= 9223372036854775807L / b) else {
    fail("native admission product is negative or overflows Int64")
  }
  a * b
}

///|
fn sum(values : ArrayView[Int64]) -> Int64 raise {
  let mut result = 0L
  for value in values {
    result = add(result, value)
  }
  result
}

///|
fn ceil_div(value : Int64, divisor : Int64) -> Int64 raise {
  guard value >= 0L && divisor > 0L else {
    fail("invalid native admission division")
  }
  add(value / divisor, if value % divisor == 0L { 0L } else { 1L })
}

///|
fn phase(
  name : String,
  common : Map[String, Int64],
  extra : Map[String, Int64],
) -> Phase raise {
  let components = common.copy()
  for key, value in extra {
    guard !components.contains(key) else {
      fail("duplicate native admission component")
    }
    components[key] = value
  }
  let mut total = 0L
  for _, bytes in components {
    total = add(total, bytes)
  }
  { name, components, envelope_bytes: total, }
}

///|
fn slab_bytes(
  rows : Int32,
  environments : Int32,
  capacity : Int32,
) -> Int64 raise {
  guard rows >= 0 && rows <= capacity && environments > 0 else {
    fail("invalid native admission replay rows")
  }
  let records = mul(rows.to_int64(), environments.to_int64())
  let capacity_records = mul(capacity.to_int64(), environments.to_int64())
  let slabs = ceil_div(records, 1024L)
  let allocated = mul(slabs, 1024L).min(capacity_records)
  // Primitive payload plus conservative directory/header allowance. No JSON
  // or per-transition compatibility objects exist in the live replay slab.
  sum([mul(allocated, 1882L), mul(slabs, 256L), 4096L])
}

///|
fn mlp(
  input : Int64,
  hidden : Array[Int32],
  output : Int64,
  normalized : Bool,
) -> Int64 raise {
  let mut count = 0L
  let mut previous = input
  for width in hidden {
    let width = width.to_int64()
    count = add(count, mul(add(previous, 1L), width))
    if normalized {
      count = add(count, mul(2L, width))
    }
    previous = width
  }
  add(count, mul(add(previous, 1L), output))
}

///|
fn active_batch(logical : Int32, micro : Int32) -> Int32 raise {
  guard logical > 0 && micro >= 0 && micro <= logical else {
    fail("microbatch must be zero (full) or within the logical batch")
  }
  if micro == 0 {
    logical
  } else {
    micro
  }
}

///|
fn known_or_max(actual : Int64, maximum : Int64) -> Int64 raise {
  guard actual >= 0L && actual <= maximum else {
    fail("native artifact bytes exceed the selected fixed capacity")
  }
  if actual == 0L {
    maximum
  } else {
    actual
  }
}
