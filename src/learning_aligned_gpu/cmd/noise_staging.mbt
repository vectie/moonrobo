///|
fn noise_staging_request(config : Json) -> Int64? raise {
  let enabled : Bool = setting(config, "noise_staging_batch", false)
  guard config is Object(fields) else {
    fail("training config must be a JSON object")
  }
  let mib = match fields.get("noise_staging_max_mib") {
    None => 16
    Some(Number(value, ..)) if value >= 1.0 &&
      value <= 256.0 &&
      value.to_int().to_double() == value => value.to_int()
    _ => fail("noise_staging_max_mib must be a JSON integer within 1..256")
  }
  if enabled {
    Some(mib.to_int64() * 1048576L)
  } else {
    None
  }
}
