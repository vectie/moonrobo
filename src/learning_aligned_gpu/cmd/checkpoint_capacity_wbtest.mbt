///|
fn checkpoint_rejects(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("invalid checkpoint capacity accepted")
  }
}

///|
fn capacity_state_fixture(
  config : Json,
  n : Int32,
  steps : Int32,
  wb : Int32,
  pb : Int32,
) -> Json {
  {
    "identity": { "config": config },
    "runtime": {
      "num_envs": Json(n),
      "capacity": Json(steps),
      "config": { "wm_batch": Json(wb), "policy_batch": Json(pb) },
    },
  }
}

///|
test "checkpoint capacity is explicit and legacy cannot infer paper dimensions" {
  assert_eq(checkpoint_capacity({ "config": {} }, true), @capacity.Initial)
  assert_eq(
    checkpoint_capacity({ "config": { "capacity_profile": "initial" } }, false),
    @capacity.Initial,
  )
  assert_eq(
    checkpoint_capacity(
      { "config": { "capacity_profile": "paper-4096" } },
      true,
    ),
    @capacity.Paper4096,
  )
  for
    bad in [
      Json::null(),
      Json(1),
      Json("paper4096"),
      Json(" paper-4096"),
      Json(["paper-4096"]),
    ] {
    checkpoint_rejects(() => {
      ignore(
        checkpoint_capacity({ "config": { "capacity_profile": bad } }, true),
      )
    })
  }
  checkpoint_rejects(() => {
    ignore(
      checkpoint_capacity(
        { "config": { "capacity_profile": "paper-4096" } },
        false,
      ),
    )
  })
  checkpoint_rejects(() => ignore(checkpoint_capacity({}, true)))
  let old = capacity_state_fixture({}, 128, 256, 128, 128)
  assert_eq(
    validate_checkpoint_capacity_dimensions(old, false),
    @capacity.Initial,
  )
  checkpoint_rejects(() => {
    ignore(
      validate_checkpoint_capacity_dimensions(
        capacity_state_fixture({}, 4096, 1000, 2048, 4096),
        true,
      ),
    )
  })
  let paper = capacity_state_fixture(
    { "capacity_profile": "paper-4096" },
    4096,
    1000,
    2048,
    4096,
  )
  assert_eq(
    validate_checkpoint_capacity_dimensions(paper, true),
    @capacity.Paper4096,
  )
  checkpoint_rejects(() => {
    ignore(validate_checkpoint_capacity_dimensions(paper, false))
  })
}

///|
test "paper stream descriptor bounds allocate no replay and retain initial envelope" {
  let replay : @stream.BlobDescriptor = {
    file: "replay.values.f64le",
    dtype: "f64le",
    shape: [1000, 4096, 234],
    count: 958464000L,
    byte_length: 7667712000L,
    sha256: "a".repeat(64),
  }
  validate_stream_members([replay], 4096L, profile=@capacity.Paper4096)
  checkpoint_rejects(() => validate_stream_members([replay], 4096L))
  let above_member = {
    ..replay,
    shape: [1073741825],
    count: 1073741825L,
    byte_length: 8589934600L,
  }
  checkpoint_rejects(() => {
    validate_stream_members([above_member], 4096L, profile=@capacity.Paper4096)
  })
  let extra = {
    ..replay,
    file: "extra.f64le",
    shape: [402653184],
    count: 402653184L,
    byte_length: 3221225472L,
  }
  checkpoint_rejects(() => {
    validate_stream_members([replay, extra], 4096L, profile=@capacity.Paper4096)
  })
  let catalog = {
    ..replay,
    file: "catalog.json",
    dtype: "u8",
    shape: [67108865],
    count: 67108865L,
    byte_length: 67108865L,
  }
  checkpoint_rejects(() => {
    validate_stream_members([catalog], 4096L, profile=@capacity.Paper4096)
  })
  checkpoint_rejects(() => {
    validate_stream_members([replay], 4194305L, profile=@capacity.Paper4096)
  })
}

///|
test "paper publication requires explicitly admitted stream phase headroom" {
  let legacy : Map[String, Int64] = {
    "host_replay_and_json_checkpoint_envelope": 17L,
  }
  assert_eq(
    checkpoint_publication_headroom(@capacity.Initial, legacy),
    1073741841L,
  )
  checkpoint_rejects(() => {
    ignore(checkpoint_publication_headroom(@capacity.Paper4096, legacy))
  })
  let admitted : Map[String, Int64] = {
    "host_checkpoint_stream_publication_headroom": 2147483648L,
  }
  assert_eq(
    checkpoint_publication_headroom(@capacity.Paper4096, admitted),
    2147483648L,
  )
  checkpoint_rejects(() => {
    ignore(
      checkpoint_publication_headroom(@capacity.Initial, {
        "host_replay_and_json_checkpoint_envelope": 9223372036854775807L,
      }),
    )
  })
}

///|
test "paper publication requires explicit positive disk budget while initial stays unchanged" {
  let empty : Map[String, Int64] = {}
  assert_eq(checkpoint_output_headroom(@capacity.Initial, empty), None)
  checkpoint_rejects(() => {
    ignore(checkpoint_output_headroom(@capacity.Paper4096, empty))
  })
  for bytes in [-1L, 0L] {
    checkpoint_rejects(() => {
      ignore(
        checkpoint_output_headroom(@capacity.Paper4096, {
          "minimum_output_free_bytes": bytes,
        }),
      )
    })
  }
  assert_eq(
    checkpoint_output_headroom(@capacity.Paper4096, {
      "minimum_output_free_bytes": 21474836480L,
    }),
    Some(21474836480L),
  )
}
