///|
fn native_test_clips() -> Array[@aligned.MotionClip] {
  Array::makei(2, c => {
    name: "contract-" + c.to_string(),
    sha256: "explicit-unit-fixture",
    rows: Array::makei(if c == 0 { 31 } else { 61 }, i => {
      let row = Array::make(36, 0.0)
      row[0] = i.to_double() / 30.0
      row[6] = 1.0
      row
    }),
  })
}

///|
async fn native_data_contract(id : String) -> Unit {
  let kin = simple_kinematics()
  let clips = native_test_clips()
  let motion = @aligned.MotionLibrary::new(clips, kin)
  match id {
    "data.resampling" => {
      assert_eq(motion.clip_end, [50, 151])
      for f in [0, 10, 49, 51, 100, 150] {
        assert_true((motion.states[f].v[0] - 1.0).abs() < 1.0e-12)
        assert_eq(motion.goal(f, 10).length(), 730)
      }
      assert_eq(motion.future_frames(50, 2), [50, 50])
      assert_eq(motion.future_frames(151, 2), [151, 151])
      let rng = @numeric.Rng::new(12U)
      let sampler = @aligned.ReturnBinSampler::new(motion.bins)
      assert_true(
        sampler
        .sample(4000, () => rng.uniform())
        .all(pair => pair.0 < motion.clip_end[motion.clip_id[pair.0]]),
      )
      assert_true(
        sampler
        .sample(400, () => rng.uniform(), min_remaining_steps=32)
        .all(pair => pair.0 + 32 <= motion.clip_end[motion.clip_id[pair.0]]),
      )
    }
    "data.duplicates" => {
      let first = @aligned.ReturnBinSampler::new(motion.bins)
      let second = @aligned.ReturnBinSampler::new(motion.bins)
      let episodes : Array[@aligned.CompletedEpisode] = [
        { bin: 0, discounted_return: 2.0, bootstrap: None, },
        { bin: 0, discounted_return: 6.0, bootstrap: None, },
        { bin: 2, discounted_return: 10.0, bootstrap: None, },
      ]
      first.update(episodes)
      second.update([episodes[2], episodes[0], episodes[1]])
      assert_eq(first.snapshot().0, [0.8, 0.0, 2.0])
      assert_eq(first.snapshot(), second.snapshot())
      assert_eq(first.snapshot().2, [2, 0, 1])
      assert_true(first.probabilities()[1] > first.probabilities()[2])
      let rng = @numeric.Rng::new(12U)
      ignore(first.sample(15, () => rng.uniform()))
      let (g, average, count) = first.snapshot()
      second.restore(g, average, count)
      let copy = rng.snapshot()
      assert_eq(
        first.sample(100, () => rng.uniform()),
        second.sample(100, () => copy.uniform()),
      )
    }
    "data.bootstrap" => {
      let sampler = @aligned.ReturnBinSampler::new(motion.bins, gamma=0.5)
      sampler.update([
        { bin: 0, discounted_return: 0.15, bootstrap: Some((2, 0.2, false)), },
        { bin: 1, discounted_return: 0.15, bootstrap: Some((2, 0.2, true)), },
      ])
      for i, value in [0.04, 0.03, 0.0] {
        assert_true((sampler.snapshot().0[i] - value).abs() < 1.0e-12)
      }
    }
    "data.reference_only" => {
      let full = @aligned.MotionLibrary::new(clips, kin)
      let empty : @aligned.Kinematics = {
        bodies: [],
        tracked: [],
        q_lo: [],
        q_hi: [],
      }
      let light = @aligned.MotionLibrary::new(
        clips,
        empty,
        compute_body_features=false,
      )
      assert_eq(light.bodies.length(), 0)
      for f in [0, 50, 151] {
        assert_eq(full.goal(f, 10), light.goal(f, 10))
      }
    }
    "data.manifest" => {
      let dir = @fs.tmpdir(prefix="native-motion-manifest-")
      defer (@fs.rmdir(dir, recursive=true) catch { _ => () })
      let csv = clips[0].rows
        .map(row => row.map(x => x.to_string()).join(","))
        .join("\n") +
        "\n"
      let bytes = @utf8.encode(csv)
      @fs.write_file(dir + "/clip.csv", bytes, create_mode=CreateNew)
      let manifest : @aligned.MotionCatalog = {
        format: "moonrobo.aligned-motion-catalog.v1",
        source_fps: 30,
        quaternion_order: "xyzw",
        clips: [
          {
            id: "clip",
            path: "clip.csv",
            sha256: @artifacts.sha256(bytes),
            layout: "root_xyz+quaternion_xyzw+g1_29_joint_angles",
            fps: None,
          },
        ],
        splits: { "train": ["clip"], "evaluation": ["clip"] },
      }
      @fs.write_file(
        dir + "/manifest.json",
        Json(manifest).stringify(),
        create_mode=CreateNew,
      )
      let loaded = @aligned.load_motion_manifest(
        dir + "/manifest.json",
        kin,
        split="evaluation",
      )
      assert_eq(loaded.motion.names, ["clip"])
      assert_eq(loaded.split, "evaluation")
      let entry = dir + "/clip.csv"
      assert_eq(
        verify_file(dir, { path: "clip.csv", sha256: @artifacts.sha256(bytes), }),
        bytes,
      )
      @fs.write_file(entry, bytes + b"\n")
      assert_true(
        (try? @aligned.load_motion_manifest(
          dir + "/manifest.json",
          kin,
          split="evaluation",
        ))
        is Err(_),
      )
    }
    _ => fail("unknown native data contract: " + id)
  }
}
