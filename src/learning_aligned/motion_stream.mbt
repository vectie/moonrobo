///|
priv struct MotionShard {
  format : String
  source_sha256 : String
  source_fps : Double
  source_frames : Int32
  frames : Int32
  state_sha256 : String
} derive(ToJson, FromJson)

///|
pub(all) struct MotionCacheAdviceReport {
  mut processed_clips : Int32
  total_clips : Int32
  mut source_verified_files : Int32
  mut source_verified_bytes : Int64
  mut shard_verified_files : Int32
  mut shard_verified_bytes : Int64
  mut new_shard_hashed_files : Int32
  mut new_shard_hashed_bytes : Int64
  mut advised_files : Int32
  mut advised_bytes : Int64
  mut unsupported_files : Int32
  mut failed_files : Int32
  mut last_advice_error : String
} derive(ToJson)

///|
fn note_motion_advice(
  report : MotionCacheAdviceReport,
  size : Int64,
  status : Int32,
  error : String,
) -> Unit {
  if status == 0 {
    report.advised_files += 1
    report.advised_bytes += size
  } else if status == 1 {
    report.unsupported_files += 1
    report.last_advice_error = error
  } else if status == 2 {
    report.failed_files += 1
    report.last_advice_error = error
  }
}

///|
async fn stream_verified_motion_hash(
  path : String,
  expected : String,
  motion_cache_advice : Bool,
) -> (String, Int64, Int32, String) {
  if !motion_cache_advice {
    return (stream_file_hash(path), 0L, -1, "")
  }
  let file = @motion_storage.AdviceFile::open(path)
  defer file.close()
  let size = file.size()
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    hash.update(file.read_at(offset, n))
    continue offset + n.to_int64()
  }
  let digest = @crypto.bytes_to_hex_string(hash.finalize())
  let status = if digest == expected { file.dontneed() } else { -1 }
  (digest, size, status, if status > 0 { file.error() } else { "" })
}

///|
async fn stream_new_motion_hash(
  path : String,
  motion_cache_advice : Bool,
) -> (String, Int64, Int32, String) {
  if !motion_cache_advice {
    return (stream_file_hash(path), 0L, -1, "")
  }
  let file = @motion_storage.AdviceFile::open(path)
  defer file.close()
  let size = file.size()
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    hash.update(file.read_at(offset, n))
    continue offset + n.to_int64()
  }
  let digest = @crypto.bytes_to_hex_string(hash.finalize())
  let status = file.dontneed()
  (digest, size, status, if status > 0 { file.error() } else { "" })
}

///|
async fn stream_file_hash(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let size = file.size()
  let hash = @crypto.SHA256::new()
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    let bytes = file.read_exactly_at(n, position=offset)
    hash.update(bytes)
    continue offset + n.to_int64()
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn stream_motion_rows(
  path : String,
  expected_sha : String,
  motion_cache_advice : Bool,
  consume : (Array[Double]) -> Unit raise,
) -> (String, Int32, Int64, Int32, String) {
  let ordinary = if motion_cache_advice {
    None
  } else {
    Some(@fs.open(path, mode=ReadOnly))
  }
  let advised = if motion_cache_advice {
    Some(@motion_storage.AdviceFile::open(path))
  } else {
    None
  }
  defer {
    if ordinary is Some(file) {
      file.close()
    }
    if advised is Some(file) {
      file.close()
    }
  }
  let size = if advised is Some(file) {
    file.size()
  } else if ordinary is Some(file) {
    file.size()
  } else {
    fail("missing motion source reader")
  }
  let hash = @crypto.SHA256::new()
  let pending : Array[Byte] = []
  let mut rows = 0
  fn line() -> Unit raise {
    for row in parse_motion_csv(@utf8.decode(Bytes::from_array(pending))) {
      guard square_norm(row[3:7].to_owned()).sqrt() >= 1.0e-6 else {
        fail("invalid motion source quaternion: " + path)
      }
      guard rows < 2147483647 else {
        fail("motion clip exceeds frame index range")
      }
      consume(row)
      rows += 1
    }
    pending.clear()
  }
  for offset = 0L; offset < size; {
    let n = (size - offset).min(65536L).to_int()
    let bytes = if advised is Some(file) {
      file.read_at(offset, n)
    } else if ordinary is Some(file) {
      file.read_exactly_at(n, position=offset)
    } else {
      fail("missing motion source reader")
    }
    hash.update(bytes)
    for byte in bytes {
      if byte == b'\n' {
        line()
      } else {
        guard pending.length() < 65536 else {
          fail("motion CSV line exceeds 64 KiB: " + path)
        }
        pending.push(byte)
      }
    }
    continue offset + n.to_int64()
  }
  if !pending.is_empty() {
    line()
  }
  guard rows >= 2 else {
    fail("motion clip requires at least two frames: " + path)
  }
  let digest = @crypto.bytes_to_hex_string(hash.finalize())
  guard digest == expected_sha else {
    fail("motion source SHA256 mismatch: " + path)
  }
  let status = if advised is Some(file) { file.dontneed() } else { -1 }
  (
    digest,
    rows,
    size,
    status,
    if status > 0 && advised is Some(file) {
      file.error()
    } else {
      ""
    },
  )
}

///|
fn interpolated_pose(
  reader : @motion_storage.Reader,
  raw_path : String,
  source_frames : Int32,
  fps : Double,
  frame : Int32,
) -> (Array[Double], Array[Double], Array[Double]) raise {
  let time = frame.to_double() * control_dt * fps
  let left = @math.floor(time).to_int().min(source_frames - 2)
  let alpha = (time - left.to_double()).max(0.0).min(1.0)
  let a = reader.read(raw_path, left, 36)
  let b = reader.read(raw_path, left + 1, 36)
  (
    Array::makei(3, j => a[j] * (1.0 - alpha) + b[j] * alpha),
    quat_to_mat(
      quat_slerp([a[6], a[3], a[4], a[5]], [b[6], b[3], b[4], b[5]], alpha),
    ),
    Array::makei(29, j => a[j + 7] * (1.0 - alpha) + b[j + 7] * alpha),
  )
}

///|
fn shard_state(row : Array[Double]) -> State {
  {
    p: row[0:3].to_owned(),
    rotation: row[3:12].to_owned(),
    v: row[12:15].to_owned(),
    w: row[15:18].to_owned(),
    q: row[18:47].to_owned(),
    qd: row[47:76].to_owned(),
  }
}

///|
async fn prepare_motion_shard(
  source : String,
  expected_sha : String,
  fps : Double,
  cache_dir : String,
  motion_cache_advice : Bool,
  report : MotionCacheAdviceReport,
) -> (String, Int32) {
  let key = @artifacts.sha256(
    @utf8.encode("moonrobo.motion-shard.f64le.v1:\{expected_sha}:\{fps}"),
  )
  let folder = cache_dir + "/" + key[:2].to_owned()
  if !@fs.exists(folder) {
    @fs.mkdir(folder, recursive=true) catch {
      error => if !@fs.exists(folder) { raise error }
    }
  }
  let path = folder + "/" + key + ".f64"
  let metadata = path + ".json"
  let lock = @fs.open(
    path + ".lock",
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  lock.lock(Exclusive)
  if @fs.exists(metadata) && @fs.exists(path) {
    let saved : MotionShard = @json.from_json(
      @json.parse(@fs.read_file(metadata).text()),
    )
    let (source_hash, source_size, source_status, source_error) = stream_verified_motion_hash(
      source, expected_sha, motion_cache_advice,
    )
    guard source_hash == expected_sha else {
      fail("motion source SHA256 mismatch: " + source)
    }
    if motion_cache_advice {
      report.source_verified_files += 1
      report.source_verified_bytes += source_size
      note_motion_advice(report, source_size, source_status, source_error)
    }
    let binary = @fs.open(path, mode=ReadOnly)
    let size = binary.size()
    binary.close()
    if saved.format == "moonrobo.motion-shard.f64le.v1" &&
      saved.source_sha256 == expected_sha &&
      saved.source_fps == fps &&
      saved.source_frames >= 2 &&
      saved.frames >= 2 &&
      size == saved.frames.to_int64() * 608L {
      let (shard_hash, shard_size, shard_status, shard_error) = stream_verified_motion_hash(
        path,
        saved.state_sha256,
        motion_cache_advice,
      )
      if shard_hash == saved.state_sha256 {
        if motion_cache_advice {
          report.shard_verified_files += 1
          report.shard_verified_bytes += shard_size
          note_motion_advice(report, shard_size, shard_status, shard_error)
        }
        return (path, saved.frames)
      }
    }
  }
  let raw_path = path + ".raw.partial"
  let raw = @motion_storage.Writer::open(raw_path)
  let (sha, source_frames, source_size, source_status, source_error) = stream_motion_rows(
    source,
    expected_sha,
    motion_cache_advice,
    row => raw.write(row),
  )
  raw.finish()
  if motion_cache_advice {
    report.source_verified_files += 1
    report.source_verified_bytes += source_size
    note_motion_advice(report, source_size, source_status, source_error)
  }
  let count = @math.floor((source_frames - 1).to_double() / fps / control_dt) +
    1.0
  guard finite(count) && count >= 2.0 && count < 2147483648.0 else {
    fail("resampled motion frame count outside supported range")
  }
  let n = count.to_int()
  let temporary = path + ".partial"
  let writer = @motion_storage.Writer::open(temporary)
  let reader = @motion_storage.Reader::new()
  // Three consecutive resampled poses reproduce the eager central differences,
  // including endpoint one-sided derivatives, without retaining a clip array.
  let mut previous = interpolated_pose(reader, raw_path, source_frames, fps, 0)
  let mut current = previous
  let mut following = interpolated_pose(reader, raw_path, source_frames, fps, 1)
  for frame in 0..<n {
    let dt = ((frame + 1).min(n - 1) - (frame - 1).max(0)).to_double() *
      control_dt
    let row = current.0.copy()
    row.append(current.1)
    row.append(vec_scale(vec_sub(following.0, previous.0), 1.0 / dt))
    row.append(
      vec_scale(so3_log(mat_mul(following.1, transpose(previous.1))), 1.0 / dt),
    )
    row.append(current.2)
    row.append(vec_scale(vec_sub(following.2, previous.2), 1.0 / dt))
    writer.write(row)
    previous = current
    current = following
    if frame + 2 < n {
      following = interpolated_pose(
        reader,
        raw_path,
        source_frames,
        fps,
        frame + 2,
      )
    }
  }
  writer.finish()
  let (state_sha, shard_size, shard_status, shard_error) = stream_new_motion_hash(
    temporary, motion_cache_advice,
  )
  if motion_cache_advice {
    report.new_shard_hashed_files += 1
    report.new_shard_hashed_bytes += shard_size
    note_motion_advice(report, shard_size, shard_status, shard_error)
  }
  let saved : MotionShard = {
    format: "moonrobo.motion-shard.f64le.v1",
    source_sha256: sha,
    source_fps: fps,
    source_frames,
    frames: n,
    state_sha256: state_sha,
  }
  @fs.rename(temporary, path, replace=true)
  @fs.write_file(
    metadata + ".partial",
    saved.to_json().stringify(),
    create_mode=CreateOrTruncate,
    permission=0o600,
    sync=Full,
  )
  @fs.rename(metadata + ".partial", metadata, replace=true)
  @fs.remove(raw_path)
  (path, n)
}

///|
async fn load_streamed_motion(
  files : Array[String],
  names : Array[String],
  hashes : Array[String],
  kin : Kinematics,
  fps : Double,
  cache_dir : String,
  compute_body_features : Bool,
  max_gather_frames : Int32,
  motion_cache_advice : Bool,
  cache_advice_report : ((MotionCacheAdviceReport) -> Unit)?,
  max_sampler_bins~ : Int32? = None,
) -> MotionLibrary {
  validate_motion_sampler_cap(max_sampler_bins)
  guard !files.is_empty() &&
    files.length() == names.length() &&
    files.length() == hashes.length() &&
    finite(fps) &&
    fps > 0.0 &&
    max_gather_frames > 0 else {
    fail("invalid streamed motion catalog or gather limit")
  }
  let paths : Array[String] = []
  let starts : Array[Int32] = []
  let ends : Array[Int32] = []
  let bins : Array[ResetBin] = []
  let first_bin : Array[Int32] = []
  let mut total = 0
  let report : MotionCacheAdviceReport = {
    processed_clips: 0,
    total_clips: files.length(),
    source_verified_files: 0,
    source_verified_bytes: 0L,
    shard_verified_files: 0,
    shard_verified_bytes: 0L,
    new_shard_hashed_files: 0,
    new_shard_hashed_bytes: 0L,
    advised_files: 0,
    advised_bytes: 0L,
    unsupported_files: 0,
    failed_files: 0,
    last_advice_error: "",
  }
  for i, file in files {
    let (path, n) = prepare_motion_shard(
      file,
      hashes[i],
      fps,
      cache_dir,
      motion_cache_advice,
      report,
    )
    guard total <= 2147483647 - n else {
      fail("catalog exceeds Int32 frame index range")
    }
    let bin_count = checked_motion_bin_count(bins.length(), n, max_sampler_bins)
    starts.push(total)
    ends.push(total + n - 1)
    paths.push(path)
    first_bin.push(bins.length())
    for b in 0..<bin_count {
      bins.push({ start: total + b * 50, clip_end: total + n - 1, })
    }
    total += n
    report.processed_clips += 1
    if motion_cache_advice &&
      (
        (report.processed_clips == 1 && report.total_clips > 1000) ||
        report.processed_clips % 1000 == 0 ||
        report.processed_clips == report.total_clips
      ) {
      if cache_advice_report is Some(emit) {
        emit(report)
      }
    }
  }
  let reader = @motion_storage.Reader::new()
  let states : FrameStore[State] = {
    count: total,
    materialize_limit: max_gather_frames,
    read: frame => {
      let clip = motion_clip_index(starts, frame)
      // A verified immutable cache failure is fatal, like an invalid eager
      // array access; no stale/zero reference is substituted on an IO failure.
      shard_state(try! reader.read(paths[clip], frame - starts[clip], 76))
    },
  }
  {
    names,
    source_sha256: hashes,
    source_fps: fps,
    states,
    bodies: {
      count: if compute_body_features {
        total
      } else {
        0
      },
      materialize_limit: max_gather_frames,
      read: frame => kin.forward(states[frame]),
    },
    clip_start: starts,
    clip_end: ends,
    clip_id: {
      count: total,
      materialize_limit: max_gather_frames,
      read: frame => motion_clip_index(starts, frame),
    },
    bins,
    frame_bin: {
      count: total,
      materialize_limit: max_gather_frames,
      read: frame => {
        let clip = motion_clip_index(starts, frame)
        first_bin[clip] +
        ((frame - starts[clip]) / 50).min((ends[clip] - starts[clip] - 1) / 50)
      },
    },
    orthonormal_heading: false,
  }
}
