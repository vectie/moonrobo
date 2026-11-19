///|
/// Calibrated raw actor features plus local SDK callback receipt age, measured
/// during capture and floor-rounded to milliseconds. This is not hardware/DDS
/// acquisition age. The control owner accounts for elapsed preparation time.
pub(all) struct Capture {
  observation : Array[Double]
  receipt_age_ms : Int64
}

///|
/// Single synchronous capture owner. Prepared SDK observers and numerical actors
/// remain borrowed. A callback can also supply deterministic software inputs.
pub struct Sensor {
  priv profile_id : String
  priv clock : () -> Int64
  priv capture : (ArrayView[Double], ArrayView[Double]) -> Capture raise
}

///|
pub fn Sensor::new(
  profile_id~ : String,
  clock~ : () -> Int64,
  capture~ : (ArrayView[Double], ArrayView[Double]) -> Capture raise,
) -> Self raise {
  guard profile_id != "" else { fail("sensor actor profile is required") }
  let last = Ref(0L)
  {
    profile_id,
    clock: () => {
      let now = clock()
      // The existing runner rejects negative/backward time. Share the same
      // observed-clock guard across its reads and the additional capture reads.
      if now < last.val {
        -1L
      } else {
        last.val = now
        now
      }
    },
    capture,
  }
}

///|
/// Borrow an already-open controller. Construction initializes no SDK and
/// publishes nothing. The observer must have been prepared from the actor's
/// selected bundle and calibrated joint/IMU mapping.
pub fn Sensor::from_sdk(
  controller : @low.Controller,
  observer : @policy.Observer,
  clock~ : () -> Int64,
) -> Self raise {
  let sample = @low.Sample::new()
  Sensor::new(profile_id=observer.profile_id(), clock~, capture=(
    previous,
    reference,
  ) => {
    controller.capture_into(sample)
    let age = sample.age_ms()
    let observation = observer.observation(sample, previous, reference)
    { observation, receipt_age_ms: age, }
  })
}

///|
fn Sensor::read(
  self : Self,
  previous : ArrayView[Double],
  reference : ArrayView[Double],
) -> (Array[Double], Int64) raise {
  let started = (self.clock)()
  guard started >= 0L else { fail("sensor clock moved backward") }
  let capture = (self.capture)(previous, reference)
  let finished = (self.clock)()
  guard finished >= started &&
    capture.receipt_age_ms >= 0L &&
    capture.receipt_age_ms < started else {
    fail("invalid sensor receipt age or capture clock")
  }
  // Use the beginning of capture, not its end or the end of feature conversion.
  // One additional millisecond covers the raw SDK's floor-rounded age; neither
  // capture/preparation time nor rounding can make old telemetry appear newer.
  (capture.observation, started - capture.receipt_age_ms - 1L)
}
