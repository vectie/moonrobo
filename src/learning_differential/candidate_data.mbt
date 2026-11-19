///|
fn simple_kinematics() -> @aligned.Kinematics {
  {
    bodies: [
      {
        name: "SimpleKinematics",
        parent: -1,
        joint: -1,
        axis: [0.0, 0.0, 1.0],
        offset_p: [0.0, 0.0, 0.0],
        offset_rotation: @aligned.identity(),
        pivot: [0.0, 0.0, 0.0],
        qref: 0.0,
      },
    ],
    tracked: [0],
    q_lo: Array::make(29, -3.0),
    q_hi: Array::make(29, 3.0),
  }
}

///|
fn field(value : Json, name : String) -> Json raise {
  guard value is Object(fields) && fields.get(name) is Some(result) else {
    fail("missing differential schema field: " + name)
  }
  result
}

///|
fn candidate_motion(
  input : Map[String, @artifacts.NumericArray],
) -> @aligned.MotionLibrary raise {
  let raw = rows(input, "motion.raw", 36)
  @aligned.MotionLibrary::new(
    [
      {
        name: "source-bound-clip",
        sha256: "source-bound-in-manifest",
        rows: raw,
      },
    ],
    simple_kinematics(),
    source_fps=number(input, "config.source_fps", default=30.0),
    compute_body_features=false,
  )
}

///|
pub fn candidate_motion_fields(
  input : Map[String, @artifacts.NumericArray],
) -> Map[String, @artifacts.NumericArray] raise {
  let motion = candidate_motion(input)
  let states = motion.states
  let n = states.length()
  let output : Map[String, @artifacts.NumericArray] = {}
  for
    (name, data) in [
      (
        "clip_len",
        motion.clip_end.mapi((i, end) => {
          (end - motion.clip_start[i] + 1).to_double()
        }),
      ),
      ("clip_start", motion.clip_start.map(x => x.to_double())),
      ("clip_end", motion.clip_end.map(x => x.to_double())),
      ("clip_id", motion.clip_id.map(x => x.to_double())),
    ] {
    output[name] = array([data.length()], data, dtype="<i8")
  }
  for
    (name, width, data) in [
      ("root_p", 3, states.map(s => s.p)),
      ("root_R", 9, states.map(s => s.rotation)),
      ("root_v", 3, states.map(s => s.v)),
      ("root_w", 3, states.map(s => s.w)),
      ("q", 29, states.map(s => s.q)),
      ("qd", 29, states.map(s => s.qd)),
      (
        "root_v_local",
        3,
        states.map(s => @aligned.mat_vec(@aligned.transpose(s.rotation), s.v)),
      ),
      (
        "root_w_local",
        3,
        states.map(s => @aligned.mat_vec(@aligned.transpose(s.rotation), s.w)),
      ),
    ] {
    output[name] = array(
      if name == "root_R" {
        [n, 3, 3]
      } else {
        [n, width]
      },
      flatten(data),
    )
  }
  output["root_gz"] = array([n], states.map(s => s.rotation[8]))
  output["future_frames"] = array(
    [n, 10],
    flatten(
      Array::makei(n, f => motion.future_frames(f, 10).map(x => x.to_double())),
    ),
    dtype="<i8",
  )
  output["goals"] = array(
    [n, 730],
    flatten(Array::makei(n, f => motion.goal(f, 10))),
  )
  output
}

///|
pub fn candidate_reset_mixture(
  input : Map[String, @artifacts.NumericArray],
  oracle : Oracle,
) -> Map[String, @artifacts.NumericArray] raise {
  let starts = get(input, "sampler.bin_start").values
  let ends = get(input, "sampler.bin_clip_end").values
  let sampler = @aligned.ReturnBinSampler::new(
    starts.mapi((i, x) => {
      ({ start: x.to_int(), clip_end: ends[i].to_int(), } : @aligned.ResetBin)
    }),
  )
  sampler.restore(
    get(input, "sampler.bin_G").values,
    get(input, "sampler.bin_w_avg").values,
    Array::make(starts.length(), 0),
  )
  let count = number(input, "config.sample_count").to_int()
  let mutable_rng : Array[@artifacts.NumericArray] = [get(input, "rng.before")]
  let sample = sampler.sample(
    count,
    () => abort("fixed ATen draw backend must not fall back to native uniforms"),
    draw_batch=(probabilities, n) => {
      let random : Map[String, @artifacts.NumericArray] = {
        "rng.before": mutable_rng[0],
        "rng.calls": array(
          [2, 3],
          [3.0, n.to_double(), 0.0, 1.0, n.to_double(), 0.0],
          dtype="<i8",
        ),
        "rng.weights.0": array(
          [probabilities.length()],
          probabilities.map(x => x.to_float().to_double()),
          dtype="<f4",
        ),
      }
      let result = try! oracle.evaluate("rng", random)
      mutable_rng[0] = result["rng.after"]
      (
        result["rng.draw.0"].values.map(x => x.to_int()),
        result["rng.draw.1"].values,
      )
    },
  )
  let ids = get(input, "sampler.update_bins").values
  let returns = get(input, "sampler.update_returns").values
  guard ids.length() == returns.length() else {
    fail("sampler update dimensions differ")
  }
  sampler.update(
    ids.mapi((i, bin) => {
      (
        { bin: bin.to_int(), discounted_return: returns[i], bootstrap: None, } :
        @aligned.CompletedEpisode)
    }),
  )
  let (returns_after, average, _) = sampler.snapshot()
  {
    "sampled_frames": array(
      [count],
      sample.map(p => p.0.to_double()),
      dtype="<i8",
    ),
    "sampled_bins": array(
      [count],
      sample.map(p => p.1.to_double()),
      dtype="<i8",
    ),
    "bin_w_avg": array([average.length()], average),
    "bin_G": array([returns_after.length()], returns_after),
    "rng.after": mutable_rng[0],
  }
}

///|
/// Full original catalog validation streams every CSV and verifies actual bytes.
pub async fn verify_catalog40(
  folder : String,
  manifest_sha256 : String,
) -> Map[String, @artifacts.NumericArray] {
  let data = @fs.read_file(folder + "/motion-manifest.json").binary()
  guard @artifacts.sha256(data) == manifest_sha256 else {
    fail("acquired catalog SHA changed")
  }
  let json = @json.parse(@utf8.decode(data))
  let source : String = @json.from_json(field(json, "source_revision"))
  guard source == "ce1572906efe6157840e8474d5a0d7aa87481e74" else {
    fail("acquired source revision differs")
  }
  let clips : Array[Json] = @json.from_json(field(json, "clips"))
  guard clips.length() == 40 else { fail("expected all 40 acquired sources") }
  let split = field(json, "splits")
  guard field(split, "train") == field(split, "evaluation") else {
    fail("catalog split identities differ")
  }
  let fps : Double = @json.from_json(field(json, "source_fps"))
  let mut frames = 0
  let mut resampled = 0
  for clip in clips {
    let filename : String = @json.from_json(field(clip, "path"))
    let sha : String = @json.from_json(field(clip, "sha256"))
    let expected : Int32 = @json.from_json(field(clip, "source_frames"))
    let bytes = verify_file(folder, { path: filename, sha256: sha, })
    let raw = @aligned.parse_motion_csv(@utf8.decode(bytes))
    guard raw.length() == expected &&
      raw.all(row => {
        row[3:7].fold(init=0.0, (sum, x) => sum + x * x).sqrt() > 0.99
      }) else {
      fail("acquired source shape/quaternion differs: " + filename)
    }
    frames += raw.length()
    resampled += @math.floor((raw.length() - 1).to_double() / fps / 0.02).to_int() +
      1
  }
  guard frames == 264705 else { fail("acquired source frame total differs") }
  {
    "clip_count": scalar(40.0),
    "source_frame_count": scalar(frames.to_double()),
    "resampled_frame_count": scalar(resampled.to_double()),
    "all_sha_valid": scalar(1.0),
    "split_equal": scalar(1.0),
    "source_revision_utf8": array(
      [source.length()],
      @utf8.encode(source).to_array().map(b => b.to_int().to_double()),
      dtype="|u1",
    ),
  }
}

///|
fn terminal_bin_contract(
  input : Map[String, @artifacts.NumericArray],
  oracle : Oracle,
  oracle_mode : Bool,
) -> Map[String, @artifacts.NumericArray] raise {
  guard get(input, "motion.raw").shape == [31, 36] else {
    fail(
      "original terminal-bin counterexample requires exactly 31 source frames",
    )
  }
  let original = oracle.evaluate("motion", input)
  guard original["clip_len"].values == [51.0] else {
    fail("upstream terminal-bin source formula changed")
  }
  let legacy = input.copy()
  legacy["sampler.bin_G"] = array([2], [0.0, 0.0], dtype="<f4")
  legacy["sampler.bin_w_avg"] = array([2], [0.5, 0.5], dtype="<f4")
  legacy["sampler.bin_start"] = array([2], [0.0, 50.0], dtype="<i8")
  legacy["sampler.bin_clip_end"] = array([2], [50.0, 50.0], dtype="<i8")
  legacy["sampler.update_bins"] = array([0], [], dtype="<i8")
  legacy["sampler.update_returns"] = array([0], [], dtype="<f4")
  legacy["config.G_max"] = scalar(10.0)
  legacy["config.sample_count"] = scalar(200.0)
  legacy["rng.before"] = get(input, "sampler.rng_before")
  let bad = oracle.evaluate("reset_sampling", legacy)
  let old_sampled = bad["sampled_frames"].values.contains(50.0)
  let (length, good_starts, sampled_terminal) = if oracle_mode {
    (51, [0.0], false)
  } else {
    let motion = candidate_motion(input)
    let sampler_state = get(input, "sampler.rng_before")
    let sampler = @aligned.ReturnBinSampler::new(motion.bins)
    let good = sampler.sample(
      200,
      () => abort("explicit ATen sampler required"),
      draw_batch=(probabilities, n) => {
        let random : Map[String, @artifacts.NumericArray] = {
          "rng.before": sampler_state,
          "rng.calls": array(
            [2, 3],
            [3.0, n.to_double(), 0.0, 1.0, n.to_double(), 0.0],
            dtype="<i8",
          ),
          "rng.weights.0": array(
            [probabilities.length()],
            probabilities.map(v => v.to_float().to_double()),
            dtype="<f4",
          ),
        }
        let draws = try! oracle.evaluate("rng", random)
        (
          draws["rng.draw.0"].values.map(v => v.to_int()),
          draws["rng.draw.1"].values,
        )
      },
    )
    (
      motion.states.length(),
      motion.bins.map(b => b.start.to_double()),
      good.any(pair => pair.0 == 50),
    )
  }
  guard old_sampled && !sampled_terminal else {
    fail("original terminal-only-bin counterexample predicate failed")
  }
  {
    "clip_len": array([1], [length.to_double()], dtype="<i8"),
    "upstream_bin_start": legacy["sampler.bin_start"],
    "candidate_bin_start": array(
      [good_starts.length()],
      good_starts,
      dtype="<i8",
    ),
    "upstream_terminal_sampled": array(
      [],
      [if old_sampled { 1.0 } else { 0.0 }],
      dtype="|b1",
    ),
    "candidate_terminal_sampled": array(
      [],
      [if sampled_terminal { 1.0 } else { 0.0 }],
      dtype="|b1",
    ),
  }
}
