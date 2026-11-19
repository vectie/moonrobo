///|
test "streamed reset bin capacity checks complete clip before allocation" {
  assert_eq(checked_motion_bin_count(0, 2, Some(1)), 1)
  assert_eq(checked_motion_bin_count(0, 51, Some(1)), 1)
  assert_eq(checked_motion_bin_count(1, 101, Some(3)), 2)
  assert_eq(checked_motion_bin_count(0, 2147483647, None), 42949673)
  for (used, frames, cap) in [(0, 52, 1), (1, 101, 2), (3, 2, 3)] {
    try checked_motion_bin_count(used, frames, Some(cap)) catch {
      _ => ()
    } noraise {
      _ => fail("clip exceeding reset-bin capacity accepted")
    }
  }
  for cap in [0, -1, 43149673] {
    try validate_motion_sampler_cap(Some(cap)) catch {
      _ => ()
    } noraise {
      _ => fail("invalid reset-bin capacity accepted")
    }
  }
}

///|
async test "manifest cap preserves complete motion and rejects cross-clip overflow" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="moonrobo-motion-cap-")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    let clips : Array[CatalogClip] = []
    for i, length in [51, 101] {
      let rows = Array::makei(length, j => {
        let row = Array::make(36, 0.0)
        row[0] = j.to_double() / 1000.0
        row[2] = 0.75
        row[6] = 1.0
        row.map(x => x.to_string()).join(",")
      })
      let csv = rows.join("\n")
      let name = "clip-\{i}"
      @fs.write_file(dir + "/" + name + ".csv", csv, create_mode=CreateNew)
      clips.push({
        id: name,
        path: name + ".csv",
        sha256: @artifacts.sha256(@utf8.encode(csv)),
        layout: "root_xyz+quaternion_xyzw+g1_29_joint_angles",
        fps: Some(50.0),
      })
    }
    let catalog : MotionCatalog = {
      format: "moonrobo.aligned-motion-catalog.v1",
      quaternion_order: "xyzw",
      source_fps: 50.0,
      clips,
      splits: { "train": ["clip-0", "clip-1"] },
    }
    let manifest = dir + "/catalog.json"
    @fs.write_file(manifest, Json(catalog).stringify(), create_mode=CreateNew)
    let old = load_motion_manifest(
      manifest,
      fixture_kin(),
      storage="mmap",
      cache_dir=dir + "/cache",
      compute_body_features=false,
    )
    let capped = load_motion_manifest(
      manifest,
      fixture_kin(),
      storage="mmap",
      cache_dir=dir + "/cache",
      compute_body_features=false,
      max_sampler_bins=Some(3),
    )
    assert_eq(old.motion.bins.length(), 3)
    assert_eq(capped.motion.names, old.motion.names)
    assert_eq(capped.motion.source_sha256, old.motion.source_sha256)
    assert_eq(capped.motion.clip_start, old.motion.clip_start)
    assert_eq(capped.motion.clip_end, old.motion.clip_end)
    assert_eq(
      capped.motion.bins.map(b => (b.start, b.clip_end)),
      old.motion.bins.map(b => (b.start, b.clip_end)),
    )
    for i in 0..<old.motion.states.length() {
      assert_eq(
        flatten_state(capped.motion.states[i]),
        flatten_state(old.motion.states[i]),
      )
      assert_eq(capped.motion.goal(i, 10), old.motion.goal(i, 10))
    }
    // The first clip fits; the second would exceed the cumulative cap.
    try
      load_motion_manifest(
        manifest,
        fixture_kin(),
        storage="mmap",
        cache_dir=dir + "/cache",
        compute_body_features=false,
        max_sampler_bins=Some(2),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("cross-clip overflow was not rejected")
    }
    // An explicit cap must not be silently ignored by the eager route.
    try
      load_motion_manifest(manifest, fixture_kin(), max_sampler_bins=Some(3))
    catch {
      _ => ()
    } noraise {
      _ => fail("eager load silently ignored sampler capacity")
    }
    // New shards and reopened shards must both obey the same cap.
    try
      load_motion_manifest(
        manifest,
        fixture_kin(),
        storage="mmap",
        cache_dir=dir + "/fresh-cache",
        compute_body_features=false,
        max_sampler_bins=Some(2),
      )
    catch {
      _ => ()
    } noraise {
      _ => fail("fresh-cache overflow was not rejected")
    }
  }
}
