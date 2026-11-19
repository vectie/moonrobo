///|
/// This is a loader-enforced data capacity, not a smaller safety multiplier.
/// None preserves the historical unknown-catalog planner and loader behavior.
fn motion_sampler_cap(
  config : Json,
  profile : @capacity.CapacityProfile,
  storage : String,
) -> Int32? raise {
  guard config is Object(fields) else {
    fail("training config must be an object")
  }
  let value = match fields.get("max_motion_sampler_bins") {
    None => return None
    Some(Number(value, ..)) if value >= 1.0 &&
      value <= 43149672.0 &&
      value.to_int().to_double() == value => value.to_int()
    _ => fail("max_motion_sampler_bins must be an integer within 1..43149672")
  }
  guard profile == @capacity.Paper4096 && storage == "mmap" else {
    fail(
      "max_motion_sampler_bins requires paper-4096 and mmap reference storage",
    )
  }
  Some(value)
}

///|
fn motion_sampler_bins_for_plan(cap : Int32?, actual : Int32?) -> Int32 raise {
  let bound = cap.unwrap_or(@admission.unknown_sampler_bins_upper())
  guard bound >= 1 && bound <= @admission.unknown_sampler_bins_upper() else {
    fail("invalid motion sampler bin capacity")
  }
  match actual {
    None => bound
    Some(count) => {
      guard count >= 1 && count <= bound else {
        fail("actual motion sampler bins exceed admitted capacity")
      }
      count
    }
  }
}
