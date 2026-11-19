///|
priv struct Cadence {
  period : Int64
  mut next : Int64
  mut last : Int64
}

///|
fn Cadence::new(started : Int64, period : Int32) -> Self raise {
  guard started >= 0L && period > 0 else {
    fail("invalid actor host clock or period")
  }
  { period: period.to_int64(), next: started, last: started, }
}

///|
fn Cadence::delay(self : Self, now : Int64) -> Int32 raise {
  guard now >= self.last else { fail("actor host clock moved backward") }
  self.last = now
  self.next += self.period
  if self.next <= now {
    // Slow synchronous work discards missed slots. Wait a full period after it,
    // rather than just yielding and immediately running another action tick.
    self.next = now + self.period
  }
  let delay = self.next - now
  guard delay > 0L && delay <= self.period else {
    fail("actor host clock overflow")
  }
  delay.to_int()
}
