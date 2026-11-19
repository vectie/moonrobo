///|
test "NPY float64 matrices scalar and empty dimensions roundtrip" {
  for
    (shape, values) in [
      ([2, 2], [0.0, -1.5, 1.0e-12, 42.0]),
      ([], [3.0]),
      ([2, 0, 3], []),
    ] {
    let decoded = @learning_artifacts.decode_npy(
      @learning_artifacts.encode_npy(shape, values),
    )
    assert_eq(decoded.shape, shape)
    assert_eq(decoded.values, values)
    assert_eq(decoded.dtype, "<f8")
  }
}

///|
test "checkpoint tensor shape and exact finite values" {
  let checkpoint = @learning_artifacts.Checkpoint::new("actor", { "seed": 12 })
  checkpoint.put("weight", [1, 2], [0.25, -0.5])
  checkpoint.validate()
  assert_eq(checkpoint.tensor("weight").values, [0.25, -0.5])
  assert_true((try? checkpoint.put("bad", [2], [1.0])) is Err(_))
}

///|
test "NPZ members preserve shapes and reject corruption" {
  let tensors : Map[String, @learning_artifacts.NumericArray] = {
    "state": { shape: [1, 2], dtype: "<f8", values: [0.5, -3.0], },
    "reward": { shape: [1], dtype: "<f8", values: [0.1], },
  }
  let archive = @learning_artifacts.encode_npz(tensors)
  let decoded = @learning_artifacts.decode_npz(archive)
  assert_eq(decoded.get("state").unwrap().values, [0.5, -3.0])
  assert_eq(decoded.get("reward").unwrap().shape, [1])
  assert_true((try? @learning_artifacts.decode_npz(b"PK")) is Err(_))
}

///|
test "NPZ preserves actual numeric dtypes and rejects silent narrowing" {
  let arrays : Map[String, @learning_artifacts.NumericArray] = {
    "float": { shape: [3], dtype: "<f4", values: [0.25, -0.5, -0.0], },
    "integer": {
      shape: [2],
      dtype: "<i8",
      values: [-4503599627370496.0, 4503599627370496.0],
    },
    "int32": {
      shape: [2],
      dtype: "<i4",
      values: [-2147483648.0, 2147483647.0],
    },
    "uint32": { shape: [2], dtype: "<u4", values: [0.0, 4294967295.0], },
    "byte": { shape: [2], dtype: "|u1", values: [0.0, 255.0], },
    "signed_byte": { shape: [2], dtype: "|i1", values: [-128.0, 127.0], },
    "boolean": { shape: [2], dtype: "|b1", values: [0.0, 1.0], },
  }
  let decoded = @learning_artifacts.decode_npz(
    @learning_artifacts.encode_npz(arrays),
  )
  for name, value in arrays {
    assert_eq(decoded[name].dtype, value.dtype)
    assert_eq(decoded[name].shape, value.shape)
    assert_eq(decoded[name].values, value.values)
  }
  assert_eq(
    decoded["float"].values[2].reinterpret_as_uint64(),
    (-0.0).reinterpret_as_uint64(),
  )
  for
    (dtype, value) in [
      ("<f4", 0.1),
      ("<i8", 0.5),
      ("<i8", 9007199254740994.0),
      ("<i4", 2147483648.0),
      ("<u4", -1.0),
      ("|u1", 256.0),
      ("|i1", -129.0),
      ("|b1", 2.0),
    ] {
    assert_true(
      try {
        ignore(@learning_artifacts.encode_npy([1], [value], dtype~))
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "standard empty gzip member and invalid compressed input" {
  let empty = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_eq(@learning_artifacts.decompress(empty), b"")
  assert_true((try? @learning_artifacts.decompress(b"\x1f\x8b")) is Err(_))
}

///|
test "training batch validates schema and horizon compatibility" {
  let raw = b"{\"format\":\"moonrobo.training-batch.v1\",\"split\":\"train\",\"window_length\":2,\"windows\":[{}],\"layout\":{\"dataset_id\":\"a\",\"model_ref\":\"g1\",\"dt_s\":0.02,\"frame_convention\":\"wxyz\",\"state_axes\":[\"s\"],\"action_axes\":[\"a\"],\"observation_axes\":[\"o\"],\"goal_axes\":[\"g\"],\"context_axes\":[\"c\"]},\"state\":[1,2],\"next_state\":[2,3],\"applied_action\":[0,0],\"observation\":[4,5],\"goal\":[6,7],\"context\":[8],\"time_s\":[0.1,0.12]}"
  let batch = @learning_artifacts.decode_window_batch(raw, "train")
  assert_eq(batch.count, 1)
  assert_eq(batch.horizon, 2)
  assert_eq(batch.start_time_s, [0.1])
  batch.compatible(batch)
  assert_true(
    (try? @learning_artifacts.decode_window_batch(raw, "test")) is Err(_),
  )
  assert_eq(
    @learning_artifacts.sha256(b"abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
// Translation of test_window_batch.py; authored for the deferred differential suite.
async test "plain gzip shards preserve every batch field and detect tampering" {
  @async.with_task_group() <| group => {
    let directory = @fs.tmpdir(prefix="moonrobo-window-batch-")
    group.add_defer(() => @fs.rmdir(directory, recursive=true))
    let layout : Json = {
      "state_axes": Array::make(14, Json::null()).to_json(),
      "action_axes": [null],
      "observation_axes": [null, null, null],
      "goal_axes": [null],
      "context_axes": [null, null],
      "dataset_id": "original",
      "model_ref": "same-model",
      "dt_s": 0.02,
      "frame_convention": "same-frame",
    }
    let data : Json = {
      "format": "moonrobo.training-batch.v1",
      "split": "train",
      "layout": layout,
      "windows": [{ "episode_id": "one", "start_step": 0 }],
      "window_length": 2,
      "state": Array::makei(28, i => i).to_json(),
      "next_state": Array::makei(28, i => i + 1).to_json(),
      "applied_action": [0.1, 0.2],
      "observation": Array::makei(6, i => i).to_json(),
      "goal": [0.3, 0.4],
      "context": [1, 1],
      "time_s": [0, 0.02],
    }
    let raw = @utf8.encode(data.stringify())
    let plain = directory + "/batch.json"
    let compressed = directory + "/batch.json.gz"
    @fs.write_file(plain, raw, create_mode=CreateOrTruncate)
    @fs.write_file(
      compressed,
      @learning_artifacts.compress_gzip(raw),
      create_mode=CreateOrTruncate,
    )
    let a = @learning_artifacts.load_window_batch(plain, "train")
    let b = @learning_artifacts.load_window_batch(compressed, "train")
    assert_eq(a.digest, @learning_artifacts.sha256(raw))
    assert_eq(a.digest, b.digest)
    assert_true(a.storage_digest != b.storage_digest)
    assert_eq(a.layout, b.layout)
    for
      (left, right) in [
        (a.state, b.state),
        (a.action, b.action),
        (a.target, b.target),
        (a.observation, b.observation),
        (a.goal, b.goal),
        (a.context, b.context),
        (a.start_time_s, b.start_time_s),
      ] {
      assert_eq(left, right)
    }
    let manifest : Json = {
      "format": "moonrobo.training-batch-shards.v1",
      "split": "train",
      "layout": layout,
      "window_length": 2,
      "shards": [
        { "file": "batch.json", "sha256": a.digest.to_json(), "windows": 1 },
        { "file": "batch.json.gz", "sha256": b.digest.to_json(), "windows": 1 },
      ],
    }
    let manifest_path = directory + "/manifest.json"
    @fs.write_file(
      manifest_path,
      manifest.stringify(),
      create_mode=CreateOrTruncate,
    )
    let combined = @learning_artifacts.load_window_batch(manifest_path, "train")
    assert_eq(combined.count, 2)
    for
      (actual, source) in [
        (combined.state, a.state),
        (combined.action, a.action),
        (combined.target, a.target),
        (combined.observation, a.observation),
        (combined.goal, a.goal),
        (combined.context, a.context),
        (combined.start_time_s, a.start_time_s),
      ] {
      assert_eq(actual, [..source, ..source])
    }
    guard data is Object(changed) && layout is Object(layout_fields) else {
      fail("test fixture must be object")
    }
    changed["applied_action"] = [0.9, 0.2]
    @fs.write_file(
      compressed,
      @learning_artifacts.compress_gzip(@utf8.encode(data.stringify())),
      create_mode=CreateOrTruncate,
    )
    assert_true(
      (try? @learning_artifacts.load_window_batch(manifest_path, "train"))
      is Err(_),
    )
    let derived_fields = layout_fields.copy()
    derived_fields["dataset_id"] = "derived"
    let derived : @learning_artifacts.WindowBatch = {
      ..b,
      layout: Json::object(derived_fields),
    }
    assert_true((try? a.compatible(derived)) is Err(_))
    a.compatible(derived, require_dataset_id=false)
    derived_fields["dt_s"] = 0.01
    assert_true(
      (try? a.compatible(derived, require_dataset_id=false)) is Err(_),
    )
  }
}
