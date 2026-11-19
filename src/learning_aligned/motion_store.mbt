///|
/// Indexed reference storage. Lazy bulk materialization is bounded; scalar
/// reads own the returned values and never expose shared native buffers.
pub struct FrameStore[A] {
  count : Int32
  read : (Int32) -> A
  materialize_limit : Int32
}

///|
pub impl[A] Debug for FrameStore[A] with fn to_repr(self) {
  Repr::opaque_("FrameStore", Repr::literal("frames=\{self.count}"))
}

///|
pub fn[A] FrameStore::eager(values : Array[A]) -> FrameStore[A] {
  {
    count: values.length(),
    read: i => values[i],
    materialize_limit: 2147483647,
  }
}

///|
pub fn[A] FrameStore::length(self : FrameStore[A]) -> Int32 {
  self.count
}

///|
pub fn[A] FrameStore::is_empty(self : FrameStore[A]) -> Bool {
  self.count == 0
}

///|
pub fn[A] FrameStore::gather(
  self : FrameStore[A],
  indices : Array[Int32],
) -> Array[A] raise {
  guard indices.length() <= self.materialize_limit else {
    fail("reference gather exceeds max_gather_frames")
  }
  for i in indices {
    guard i >= 0 && i < self.count else {
      fail("motion frame index out of bounds")
    }
  }
  indices.map(i => self[i])
}

///|
pub fn[A] FrameStore::op_get(self : FrameStore[A], index : Int32) -> A {
  if index < 0 || index >= self.count {
    abort("motion frame index out of bounds")
  }
  (self.read)(index)
}

///|
pub fn[A, B] FrameStore::map(self : FrameStore[A], f : (A) -> B) -> Array[B] {
  if self.count > self.materialize_limit {
    abort("full motion materialization exceeds max_gather_frames")
  }
  Array::makei(self.count, i => f(self[i]))
}

///|
pub fn[A] FrameStore::all(self : FrameStore[A], f : (A) -> Bool) -> Bool {
  for i in 0..<self.count {
    if !f(self[i]) {
      return false
    }
  }
  true
}

///|
fn motion_clip_index(starts : Array[Int32], frame : Int32) -> Int32 {
  let mut lo = 0
  let mut hi = starts.length()
  while lo + 1 < hi {
    let middle = lo + (hi - lo) / 2
    if starts[middle] <= frame {
      lo = middle
    } else {
      hi = middle
    }
  }
  lo
}
