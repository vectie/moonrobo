///|
fn stream_test_state(s : State) -> Array[Array[Double]] {
  [s.p, s.rotation, s.v, s.w, s.q, s.qd]
}

///|
fn stream_test_body(b : BodyState) -> Array[Array[Double]] {
  [b.p, b.rotation, b.v, b.w]
}

///|
async test "bounded disk motion matches eager interpolation FK goals and terminal bins" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="moonrobo-stream-motion-")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    let rows = Array::makei(361, i => {
      let row = Array::make(36, 0.0)
      let t = i.to_double() / 120.0
      row[0] = 0.2 * t * t
      row[1] = -0.3 * t
      row[2] = 0.74 + 0.02 * @math.sin(t)
      row[5] = @math.sin(t * 0.2)
      row[6] = @math.cos(t * 0.2)
      for j in 7..<36 {
        row[j] = 0.07 * @math.sin(t + j.to_double())
      }
      row
    })
    let short = rows[:4].to_owned()
    let sources = [rows, short]
    let clips : Array[CatalogClip] = []
    for i, source in sources {
      let name = "source-\{i}"
      let csv = "# comment\n\n" +
        source.map(row => row.map(x => x.to_string()).join(",")).join("\r\n")
      @fs.write_file(dir + "/" + name + ".csv", csv, create_mode=CreateNew)
      clips.push({
        id: name,
        path: name + ".csv",
        sha256: @artifacts.sha256(@utf8.encode(csv)),
        layout: "root_xyz+quaternion_xyzw+g1_29_joint_angles",
        fps: Some(120.0),
      })
    }
    let catalog : MotionCatalog = {
      format: "moonrobo.aligned-motion-catalog.v1",
      quaternion_order: "xyzw",
      source_fps: 120.0,
      clips,
      splits: { "train": ["source-0", "source-1"] },
    }
    let manifest = dir + "/catalog.json"
    @fs.write_file(
      manifest,
      catalog.to_json().stringify(),
      create_mode=CreateNew,
    )
    let kin = fixture_kin()
    let eager = load_motion_manifest(manifest, kin)
    assert_true(
      (Ok(load_motion_manifest(manifest, kin, motion_cache_advice=true)) catch {
        e => Err(e)
      })
      is Err(_),
    )
    let disk = load_motion_manifest(
      manifest,
      kin,
      storage="mmap",
      cache_dir=dir + "/cache",
      max_gather_frames=16,
    )
    let advice_reports : Array[MotionCacheAdviceReport] = []
    let advised = load_motion_manifest(
      manifest,
      kin,
      storage="mmap",
      cache_dir=dir + "/cache",
      motion_cache_advice=true,
      cache_advice_report=Some(report => advice_reports.push(report)),
    )
    assert_eq(advised.motion.clip_end, disk.motion.clip_end)
    assert_eq(advice_reports.length(), 1)
    assert_eq(advice_reports[0].processed_clips, 2)
    assert_eq(advice_reports[0].source_verified_files, 2)
    assert_eq(advice_reports[0].shard_verified_files, 2)
    assert_eq(advice_reports[0].new_shard_hashed_files, 0)
    assert_eq(
      advice_reports[0].advised_files +
      advice_reports[0].unsupported_files +
      advice_reports[0].failed_files,
      4,
    )
    assert_eq(disk.manifest_sha256, eager.manifest_sha256)
    assert_eq(disk.motion.clip_start, eager.motion.clip_start)
    assert_eq(disk.motion.clip_end, eager.motion.clip_end)
    assert_eq(
      disk.motion.bins.map(b => (b.start, b.clip_end)),
      eager.motion.bins.map(b => (b.start, b.clip_end)),
    )
    for i in 0..<eager.motion.states.length() {
      assert_eq(
        stream_test_state(disk.motion.states[i]),
        stream_test_state(eager.motion.states[i]),
      )
      assert_eq(
        disk.motion.bodies[i].map(stream_test_body),
        eager.motion.bodies[i].map(stream_test_body),
      )
      assert_eq(disk.motion.clip_id[i], eager.motion.clip_id[i])
      assert_eq(disk.motion.frame_bin[i], eager.motion.frame_bin[i])
      assert_eq(disk.motion.goal(i, 10), eager.motion.goal(i, 10))
    }
    assert_true(
      (Ok(disk.motion.states.gather(Array::make(17, 0))) catch { e => Err(e) })
      is Err(_),
    )
    assert_eq(disk.motion.states.gather([0, 4]).length(), 2)
    let eager_30 = load_motion_directory(
      dir,
      kin,
      source_fps=30.0,
      compute_body_features=false,
    )
    let disk_30 = load_motion_directory(
      dir,
      kin,
      source_fps=30.0,
      compute_body_features=false,
      storage="mmap",
      cache_dir=dir + "/cache",
    )
    assert_true(disk_30.motion.bodies.is_empty())
    assert_eq(disk_30.motion.clip_end, eager_30.motion.clip_end)
    for i in 0..<eager_30.motion.states.length() {
      assert_eq(
        stream_test_state(disk_30.motion.states[i]),
        stream_test_state(eager_30.motion.states[i]),
      )
    }
    // Reopen from completed shards, then corrupt one shard to require rebuilding.
    let reopened = load_motion_manifest(
      manifest,
      kin,
      storage="mmap",
      cache_dir=dir + "/cache",
    )
    assert_eq(
      stream_test_state(reopened.motion.states[29]),
      stream_test_state(eager.motion.states[29]),
    )
    let fps = 120.0
    let key = @artifacts.sha256(
      @utf8.encode("moonrobo.motion-shard.f64le.v1:\{clips[0].sha256}:\{fps}"),
    )
    let path = dir + "/cache/" + key[:2].to_owned() + "/" + key + ".f64"
    @fs.write_file(path, b"broken", create_mode=TruncateExisting)
    let rebuilt = load_motion_manifest(
      manifest,
      kin,
      storage="mmap",
      cache_dir=dir + "/cache",
    )
    assert_eq(
      stream_test_state(rebuilt.motion.states[29]),
      stream_test_state(eager.motion.states[29]),
    )
    @fs.write_file(dir + "/source-0.csv", "bad", create_mode=TruncateExisting)
    assert_true(
      (Ok(
        load_motion_manifest(
          manifest,
          kin,
          storage="mmap",
          cache_dir=dir + "/cache",
        ),
      ) catch {
        e => Err(e)
      })
      is Err(_),
    )
  }
}

///|
async test "motion advice reader retains verified inode across path replacement" {
  @async.with_task_group() <| group => {
    let dir = @fs.tmpdir(prefix="moonrobo-motion-advice-inode-")
    group.add_defer(() => @fs.rmdir(dir, recursive=true))
    assert_true(
      (Ok(@motion_storage.AdviceFile::open(dir)) catch { e => Err(e) })
      is Err(_),
    )
    let original = dir + "/original.bin"
    let moved = dir + "/moved.bin"
    let replacement = dir + "/replacement.bin"
    let bytes = Array::make(65538, b'a')
    bytes[65536] = b'z'
    @fs.write_file(original, Bytes::from_array(bytes), create_mode=CreateNew)
    @fs.write_file(replacement, b"new", create_mode=CreateNew)
    let file = @motion_storage.AdviceFile::open(original)
    defer file.close()
    assert_eq(file.size(), 65538L)
    assert_eq(file.read_at(65534L, 4), b"aaza")
    @fs.rename(original, moved, replace=false)
    @fs.rename(replacement, original, replace=false)
    assert_eq(file.read_at(65534L, 4), b"aaza")
    let status = file.dontneed()
    assert_true(status == 0 || status == 1)
    assert_true((Ok(file.read_at(65537L, 2)) catch { e => Err(e) }) is Err(_))
    @fs.write_file(moved, b"changed", create_mode=TruncateExisting)
    assert_true((Ok(file.read_at(1024L, 4)) catch { e => Err(e) }) is Err(_))
    assert_true((Ok(file.dontneed()) catch { e => Err(e) }) is Err(_))
  }
}
