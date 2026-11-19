///|
fn capacity_rejects(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("invalid audit capacity accepted")
  }
}

///|
test "audit saved profile defaults initial and never infers larger dimensions" {
  assert_eq(checkpoint_capacity({ "config": {} }, false), @capacity.Initial)
  assert_eq(
    checkpoint_capacity(
      { "config": { "capacity_profile": "paper-4096" } },
      true,
    ),
    @capacity.Paper4096,
  )
  for bad in [Json::null(), Json(1), Json("paper4096"), Json(["paper-4096"])] {
    capacity_rejects(() => {
      ignore(
        checkpoint_capacity({ "config": { "capacity_profile": bad } }, true),
      )
    })
  }
  capacity_rejects(() => {
    ignore(
      checkpoint_capacity(
        { "config": { "capacity_profile": "paper-4096" } },
        false,
      ),
    )
  })
  for n in [128, 4096] {
    let state : Json = {
      "identity": { "config": {} },
      "runtime": {
        "num_envs": Json(n),
        "capacity": 256,
        "config": { "wm_batch": 128, "policy_batch": 128 },
      },
    }
    if n == 128 {
      assert_eq(validate_capacity_state(state, true), @capacity.Initial)
    } else {
      capacity_rejects(() => ignore(validate_capacity_state(state, true)))
    }
  }
}

///|
test "audit paper replay byte bounds do not decode or allocate numeric payload" {
  let replay : @stream.BlobDescriptor = {
    file: "replay.values.f64le",
    dtype: "f64le",
    shape: [1000, 4096, 234],
    count: 958464000L,
    byte_length: 7667712000L,
    sha256: "a".repeat(64),
  }
  let files : Map[String, String] = {
    "world.pt": "world",
    "policy.pt": "policy",
    "critic.pt": "critic",
    "state.json": "state",
    "replay.values.f64le": replay.sha256,
  }
  assert_eq(
    stream_inventory([replay], files, 4096L, profile=@capacity.Paper4096),
    7667712000L,
  )
  capacity_rejects(() => ignore(stream_inventory([replay], files, 4096L)))
  let too_large = {
    ..replay,
    shape: [1073741825],
    count: 1073741825L,
    byte_length: 8589934600L,
  }
  capacity_rejects(() => {
    ignore(
      stream_inventory([too_large], files, 4096L, profile=@capacity.Paper4096),
    )
  })
  capacity_rejects(() => {
    ignore(
      stream_inventory([replay], files, 4194305L, profile=@capacity.Paper4096),
    )
  })
  let extra = {
    ..replay,
    file: "extra.f64le",
    shape: [402653184],
    count: 402653184L,
    byte_length: 3221225472L,
  }
  let expanded = files.copy()
  expanded[extra.file] = extra.sha256
  capacity_rejects(() => {
    ignore(
      stream_inventory(
        [replay, extra],
        expanded,
        4096L,
        profile=@capacity.Paper4096,
      ),
    )
  })
}
