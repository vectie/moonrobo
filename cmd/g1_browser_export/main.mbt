///|
async fn checksum(path : String) -> String {
  let f = @fs.open(path, mode=ReadOnly)
  defer f.close()
  let hash = @crypto.SHA256::new()
  let size = f.size()
  for pos = 0L; pos < size; {
    let n = (size - pos).min(1048576L).to_int()
    hash.update(f.read_exactly_at(n, position=pos))
    continue pos + n.to_int64()
  }
  @crypto.bytes_to_hex_string(hash.finalize())
}

///|
async fn read_json(path : String) -> Json {
  @json.parse(@fs.read_file(path).text())
}

///|
async fn write_layers(
  file : @fs.File,
  cursor : Ref[Int32],
  network : @gpu.Network,
) -> Json {
  let layers : Array[Json] = []
  for layer in network.layers {
    let shape = layer.weight.shape()
    let start = cursor.val
    let params = [layer.weight, layer.bias]
    if layer.norm_weight is Some(w) && layer.norm_bias is Some(b) {
      params.append([w, b])
    }
    for tensor in params {
      let flat = tensor.stop_gradient().reshape([-1])
      let n = flat.shape()[0]
      for pos = 0; pos < n; {
        let count = (n - pos).min(65536)
        let values = flat.narrow(0, pos, count).values()
        guard values.all(@numeric.finite) else {
          fail("nonfinite checkpoint value")
        }
        let bits = values.map(v => v.to_float().reinterpret_as_uint())
        let bytes = Bytes::makei(count * 4, i => {
          (bits[i / 4] >> (i % 4 * 8)).to_byte()
        })
        file.write_at(bytes, position=cursor.val.to_int64() * 4L)
        cursor.val += count
        continue pos + count
      }
    }
    layers.push({
      "start": start,
      "input": shape[1],
      "output": shape[0],
      "layerNorm": params.length() == 4,
    })
  }
  Json(layers)
}

///|
fn state_at(bytes : Bytes, frame : Int32) -> @aligned.State {
  let row = Array::makei(76, i => {
    let mut bits = 0L
    for j in 0..<8 {
      bits = bits |
        (bytes[(frame * 76 + i) * 8 + j].to_int().to_int64() << (j * 8))
    }
    bits.reinterpret_as_double()
  })
  {
    p: row[:3].to_owned(),
    rotation: row[3:12].to_owned(),
    v: row[12:15].to_owned(),
    w: row[15:18].to_owned(),
    q: row[18:47].to_owned(),
    qd: row[47:76].to_owned(),
  }
}

///|
fn restore_norm(
  norm : @gpu.RunningNorm,
  saved : @aligned.NormSnapshot,
  backend : @tensor.Backend,
) -> Unit raise {
  norm.mean = backend.from_values(
    [norm.dim],
    saved.mean,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  norm.variance = backend.from_values(
    [norm.dim],
    saved.variance,
    cuda_device=-1,
    requires_grad=false,
    dtype=Float32,
  )
  norm.count = saved.count
}

///|
async fn main {
  guard @env.args() is [_, lib, source, dest, clip_file, kind] &&
    ["actor", "actor-world"].contains(kind) else {
    fail(
      "g1_browser_export TENSOR_LIB CHECKPOINT_DIR NEW_OUTPUT REAL_F64_SHARD actor|actor-world",
    )
  }
  guard !@fs.exists(dest) else { fail("output already exists") }
  let receipt = read_json(source + "/receipt.json")
  guard receipt is { "files": Object(files), "iteration": iteration, .. } else {
    fail("checkpoint receipt required")
  }
  for
    name in (if kind == "actor-world" {
      ["policy.pt", "state.json", "world.pt"]
    } else {
      ["policy.pt", "state.json"]
    }) {
    guard files.get(name) == Some(Json(checksum(source + "/" + name))) else {
      fail("digest mismatch: " + name)
    }
  }
  guard read_json(source + "/state.json")
    is {
      "learner": learner,
      "identity": identity,
      "runtime": { "iteration": it, .. },
      ..
    } &&
    it == iteration else {
    fail("invalid source")
  }
  let meta : @gpu.CheckpointMetadata = @json.from_json(learner)
  let spec = @inference.ActorSpec::from_checkpoint(meta)
  guard spec.hist == 10 &&
    spec.goal_frames == 10 &&
    spec.mode() == Smc &&
    spec.mlp_precision == Some(Bf16) &&
    spec.policy_linear_mode == Some(NativeLinear) &&
    meta.config.wm_hidden == [2048, 2048, 2048] &&
    meta.world_layer_norm_mode == Some(Native) &&
    meta.heading_mode == Some(OrthonormalAtlas) else {
    fail("unsupported demo contract")
  }
  let b = @tensor.Backend::open(lib)
  let actor = @inference.Actor::load_archive(b, source + "/policy.pt", spec)
  let tmp = dest + ".partial-" + @async.now().to_string()
  @fs.mkdir(tmp)
  let cursor = Ref::new(0)
  let bin = @fs.open(
    tmp + "/weights.f32",
    mode=WriteOnly,
    create_mode=CreateNew,
  )
  defer bin.close()
  let nets : Map[String, Json] = {}
  nets["encoder"] = write_layers(bin, cursor, actor.policy.encoder)
  nets["decoder"] = write_layers(bin, cursor, actor.policy.decoder)
  let world = if kind == "actor-world" {
    let w = @gpu.WorldModel::new(
      b,
      @numeric.Rng::new(1U),
      hidden=meta.config.wm_hidden,
      layer_norm_mode=Native,
      linear_mode=NativeLinear,
      mlp_precision=Bf16,
    )
    b.adam(w.net.parameters()).load(source + "/world.pt")
    restore_norm(w.input_norm, meta.normalizers[0], b)
    restore_norm(w.output_norm, meta.normalizers[1], b)
    nets["world"] = write_layers(bin, cursor, w.net)
    Some(w)
  } else {
    None
  }
  let clip = @fs.read_file(clip_file).binary()
  let frames = clip.length() / 608
  guard frames >= 40 && clip.length() == frames * 608 else {
    fail("expected complete 76D motion shard")
  }
  let fixtures : Array[Json] = []
  for frame in [0, 12, frames / 2, frames - 2] {
    let state = state_at(clip, frame)
    let future = Array::makei(10, i => {
      state_at(clip, (frame + i + 1).min(frames - 1))
    })
    let xi = Array::make(33, 0.0)
    xi[0] = 1.0
    let history = Array::makei(10, i => {
      let t = (frame - 9 + i).max(0)
      let s = state_at(clip, t)
      @aligned.observation(
        s,
        Array::make(29, 0.0),
        xi,
        @aligned.default_joint_positions(),
        s,
        Smc,
      )
    })
    let goal = @aligned.goal_from_states(state, future, atlas=true)
    let act = actor.forward(history, goal)
    let row : Map[String, Json] = {
      "frame": Json(frame),
      "history": Json(history),
      "goal": Json(goal),
      "action": Json(act),
    }
    if world is Some(w) {
      let vector = (a : Array[Double]) => {
        b.from_values(
          [1, a.length()],
          a,
          cuda_device=-1,
          requires_grad=false,
          dtype=Float32,
        )
      }
      let s : @geo.State = {
        p: vector(state.p),
        rotation: vector(state.rotation).reshape([1, 3, 3]),
        v: vector(state.v),
        w: vector(state.w),
        q: vector(state.q),
        qd: vector(state.qd),
      }
      let inputs = @geo.world_inputs(
        b,
        s,
        vector(act),
        @geo.normalize_xi(b, vector(xi)),
        heading_mode=OrthonormalAtlas,
      )
      let delta = w.delta(inputs)
      let next = @geo.world_integrate(
        b,
        s,
        delta,
        heading_mode=OrthonormalAtlas,
      )
      row["worldInput"] = Json(inputs.values())
      row["delta"] = Json(delta.values())
      row["nextState"] = Json(
        [
          ..next.p.values(),
          ..next.rotation.values(),
          ..next.v.values(),
          ..next.w.values(),
          ..next.q.values(),
          ..next.qd.values(),
        ],
      )
    }
    fixtures.push(Json(row))
  }
  let manifest : Json = {
    "format": "moonrobo.browser-g1.v1",
    "iteration": iteration,
    "sha256": Json(checksum(tmp + "/weights.f32")),
    "floats": cursor.val,
    "sourceFiles": Json(files),
    "contract": spec.contract(),
    "normalizers": Json(meta.normalizers[:4].to_owned()),
    "networks": Json(nets),
    "sceneSha256": match identity {
      { "scene_sha256": sha, .. } => sha
      _ => fail("missing scene")
    },
  }
  @fs.write_file(
    tmp + "/model.json",
    manifest.stringify(),
    create_mode=CreateNew,
  )
  @fs.write_file(
    tmp + "/native-fixtures.json",
    Json(fixtures).stringify(),
    create_mode=CreateNew,
  )
  @fs.rename(tmp, dest, replace=false)
  println(
    (
      {
        "saved": Json(dest),
        "iteration": iteration,
        "float_count": cursor.val,
        "native_fixtures": fixtures.length(),
      } : Json).stringify(),
  )
}
