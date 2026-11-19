///|
fn rejects(action : () -> Unit raise) -> Unit raise {
  try action() catch {
    _ => ()
  } noraise {
    _ => fail("expected capacity validation rejection")
  }
}

///|
test "capacity names are explicit exact identities" {
  for
    (name, expected) in [
      ("initial", @learning_native_capacity.Initial),
      ("paper-4096", @learning_native_capacity.Paper4096),
    ] {
    let profile = @learning_native_capacity.CapacityProfile::parse(name)
    assert_eq(profile, expected)
    assert_eq(profile.name(), name)
  }
  for
    name in [
      "", "paper4096", "Paper4096", " initial", "initial\n", "paper", "smc",
    ] {
    rejects(() => ignore(@learning_native_capacity.CapacityProfile::parse(name)))
  }
}

///|
test "Initial retains existing dimensions and byte caps" {
  let profile = @learning_native_capacity.Initial
  let limits = profile.limits()
  assert_eq(limits.max_environments, 128)
  assert_eq(limits.max_world_batch, 128)
  assert_eq(limits.max_policy_batch, 128)
  assert_eq(limits.max_replay_steps, 256)
  assert_eq(limits.max_replay_values, 16777216L)
  assert_eq(limits.max_tensor_values, 16777216L)
  assert_eq(limits.max_reference_frames, 131072)
  assert_eq(limits.max_stream_total_bytes, 536870912L)
  assert_eq(limits.max_stream_member_bytes, 536870912L)
  let replay = profile.validate_dimensions(
    environments=128,
    world_batch=128,
    policy_batch=128,
    replay_steps=256,
  )
  assert_eq(replay.records, 32768L)
  assert_eq(replay.values, 7667712L)
  assert_eq(replay.float64_bytes, 61341696L)
  assert_eq(replay.payload_bytes, 61669376L)
  rejects(() => {
    ignore(
      profile.validate_dimensions(
        environments=4096,
        world_batch=2048,
        policy_batch=4096,
        replay_steps=1000,
      ),
    )
  })
}

///|
test "paper counts are exact arithmetic with no corpus allocation" {
  let profile = @learning_native_capacity.Paper4096
  let limits = profile.limits()
  let replay = profile.validate_dimensions(
    environments=4096,
    world_batch=2048,
    policy_batch=4096,
    replay_steps=1000,
  )
  assert_eq(replay.records, 4096000L)
  assert_eq(replay.values, 958464000L)
  assert_eq(replay.float64_bytes, 7667712000L)
  assert_eq(replay.indices_bytes, 32768000L)
  assert_eq(replay.flags_bytes, 8192000L)
  assert_eq(replay.payload_bytes, 7708672000L)
  assert_eq(limits.max_replay_values, replay.values)
  assert_eq(limits.max_reference_frames, 33 * 4096)
  let observable = 4096L *
    (133L + 10L * 102L + 33L * (71L + 73L * 10L) + 32L * 102L + 5L * 32L)
  assert_eq(limits.max_tensor_values, observable)
  assert_eq(observable, 127016960L)
  assert_true(replay.float64_bytes < limits.max_stream_member_bytes)
  assert_eq(limits.max_stream_member_bytes, 8589934592L)
  assert_eq(limits.max_stream_total_bytes, 10737418240L)
  let total = profile.validate_stream_totals(
    [replay.float64_bytes, replay.indices_bytes, replay.flags_bytes, 67108864L],
    state_bytes=4194304L,
  )
  assert_eq(total, 7779975168L)
}

///|
test "dimensions reject nonpositive and one-past-profile counts" {
  for
    profile in [
      @learning_native_capacity.Initial,
      @learning_native_capacity.Paper4096,
    ] {
    let cap = profile.limits()
    for n in [0, -1, cap.max_environments + 1, 2147483647] {
      rejects(() => {
        ignore(
          profile.validate_dimensions(
            environments=n,
            world_batch=1,
            policy_batch=1,
            replay_steps=1,
          ),
        )
      })
    }
    for n in [0, -1, cap.max_world_batch + 1] {
      rejects(() => {
        ignore(
          profile.validate_dimensions(
            environments=1,
            world_batch=n,
            policy_batch=1,
            replay_steps=1,
          ),
        )
      })
    }
    for n in [0, -1, cap.max_policy_batch + 1] {
      rejects(() => {
        ignore(
          profile.validate_dimensions(
            environments=1,
            world_batch=1,
            policy_batch=n,
            replay_steps=1,
          ),
        )
      })
    }
    for n in [0, -1, cap.max_replay_steps + 1] {
      rejects(() => {
        ignore(
          profile.validate_dimensions(
            environments=1,
            world_batch=1,
            policy_batch=1,
            replay_steps=n,
          ),
        )
      })
    }
    let small = profile.validate_dimensions(
      environments=1,
      world_batch=1,
      policy_batch=1,
      replay_steps=1,
    )
    assert_eq(small.payload_bytes, 1882L)
  }
}

///|
test "stream totals include catalog and state once and retain metadata bounds" {
  for
    profile in [
      @learning_native_capacity.Initial,
      @learning_native_capacity.Paper4096,
    ] {
    let cap = profile.limits()
    profile.validate_catalog_bytes(1L)
    profile.validate_catalog_bytes(67108864L)
    for n in [-1L, 0L, 67108865L, 9223372036854775807L] {
      rejects(() => profile.validate_catalog_bytes(n))
    }
    assert_eq(profile.validate_stream_totals([0L, 7L], state_bytes=3L), 10L)
    assert_eq(
      profile.validate_stream_totals(Array::make(64, 0L), state_bytes=1L),
      1L,
    )
    rejects(() => ignore(profile.validate_stream_totals([], state_bytes=1L)))
    rejects(() => {
      ignore(
        profile.validate_stream_totals(Array::make(65, 0L), state_bytes=1L),
      )
    })
    for n in [-1L, cap.max_stream_member_bytes + 1L, 9223372036854775807L] {
      rejects(() => ignore(profile.validate_stream_totals([n], state_bytes=1L)))
    }
    for n in [-1L, 0L, 4194305L] {
      rejects(() => ignore(profile.validate_stream_totals([1L], state_bytes=n)))
    }
  }
  assert_eq(
    @learning_native_capacity.Initial.validate_stream_totals(
      [536870911L],
      state_bytes=1L,
    ),
    536870912L,
  )
  rejects(() => {
    ignore(
      @learning_native_capacity.Initial.validate_stream_totals(
        [536870912L],
        state_bytes=1L,
      ),
    )
  })
  assert_eq(
    @learning_native_capacity.Paper4096.validate_stream_totals(
      [8589934592L, 2147483647L],
      state_bytes=1L,
    ),
    10737418240L,
  )
  rejects(() => {
    ignore(
      @learning_native_capacity.Paper4096.validate_stream_totals(
        [8589934592L, 2147483648L],
        state_bytes=1L,
      ),
    )
  })
}

///|
test "APIC serialization bounds remain explicit fixed profiles" {
  let initial = @learning_native_capacity.Initial.limits()
  assert_eq(initial.max_apic_numeric_union_bytes, 536870912L)
  assert_eq(initial.max_apic_payload_total_bytes, 1073741824L)
  assert_eq(initial.max_apic_payload_file_bytes, 268435456L)
  assert_eq(initial.max_apic_payload_files, 4096)
  assert_eq(initial.max_apic_oracle_bytes, 4194304L)
  assert_eq(initial.max_apic_manifest_bytes, 4194304L)
  let paper = @learning_native_capacity.Paper4096.limits()
  assert_eq(paper.max_apic_numeric_union_bytes, 2147483648L)
  assert_eq(paper.max_apic_payload_total_bytes, 4294967296L)
  assert_eq(paper.max_apic_payload_file_bytes, 1073741824L)
  assert_eq(paper.max_apic_payload_files, 4096)
  assert_eq(paper.max_apic_oracle_bytes, 67108864L)
  assert_eq(paper.max_apic_manifest_bytes, 67108864L)
}
