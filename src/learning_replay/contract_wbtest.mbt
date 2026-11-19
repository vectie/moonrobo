///|
fn fixture() -> PoseReplay {
  {
    format: "moonrobo.pose-replay.v1",
    model: {
      id: "test-model",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      coordinate_system: "right-handed-z-up",
      bodies: [
        { id: "0", name: "world", parent_id: None, },
        { id: "1", name: "pelvis", parent_id: Some("0"), },
      ],
      visuals: [
        {
          id: "body-box",
          body_id: "1",
          geometry: { "kind": "box", "size": [0.2, 0.1, 0.3] },
          local_position: [0, 0, 0],
          local_quaternion_wxyz: [1, 0, 0, 0],
          rgba: [0.5, 0.5, 0.5, 1],
        },
      ],
    },
    clips: [
      {
        id: "recorded",
        label: "recorded",
        source_start_time_s: 20,
        source: {},
        tracks: [
          {
            id: "physics",
            kind: "physics",
            label: "physics",
            frames: [
              {
                time_s: 0,
                bodies: [
                  {
                    body_id: "0",
                    position: [0, 0, 0],
                    quaternion_wxyz: [1, 0, 0, 0],
                  },
                  {
                    body_id: "1",
                    position: [4, 3, 0.8],
                    quaternion_wxyz: [1, 0, 0, 0],
                  },
                ],
              },
              {
                time_s: 0.02,
                bodies: [
                  {
                    body_id: "0",
                    position: [0, 0, 0],
                    quaternion_wxyz: [1, 0, 0, 0],
                  },
                  {
                    body_id: "1",
                    position: [4.1, 3, 0.7],
                    quaternion_wxyz: [1, 0, 0, 0],
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
    source: {},
  }
}

///|
test "root body accepts null or omitted parent and rejects invalid parent types" {
  let roots : Array[Json] = [
    { "id": "0", "name": "root" },
    { "id": "0", "name": "root", "parent_id": Json::null() },
  ]
  for value in roots {
    let body : Body = @json.from_json(value)
    assert_eq(body.parent_id, None)
  }
  let child : Body = @json.from_json({
    "id": "1",
    "name": "child",
    "parent_id": "0",
  })
  assert_eq(child.parent_id, Some("0"))
  try {
    let _ : Body = @json.from_json({
      "id": "1",
      "name": "child",
      "parent_id": 7,
    })
  } catch {
    _ => ()
  } noraise {
    _ => fail("numeric replay parent accepted")
  }
}

///|
test "recorded frame preserves root displacement and absolute reference origin" {
  let replay = validate_json(fixture().to_json())
  assert_eq(replay.clips[0].source_start_time_s, 20)
  assert_eq(replay.clips[0].tracks[0].frames[1].bodies[1].position[0], 4.1)
  assert_eq(replay.clips[0].tracks[0].frames[1].time_s, 0.02)
}

///|
test "missing body cannot inherit an old frame pose" {
  let replay = fixture()
  ignore(replay.clips[0].tracks[0].frames[1].bodies.pop())
  try replay.validate() catch {
    _ => ()
  } noraise {
    _ => fail("missing pose accepted")
  }
}

///|
test "timestamps must strictly advance and quaternions must be unit" {
  let replay = fixture()
  replay.clips[0].tracks[0].frames[1] = replay.clips[0].tracks[0].frames[0]
  try replay.validate() catch {
    _ => ()
  } noraise {
    _ => fail("duplicate time accepted")
  }
  let replay = fixture()
  replay.clips[0].tracks[0].frames[0].bodies[0].quaternion_wxyz[0] = 0
  try replay.validate() catch {
    _ => ()
  } noraise {
    _ => fail("zero quaternion accepted")
  }
}

///|
test "content-addressed meshes reject remote and traversing paths" {
  assert_false(safe_asset_path("../mesh.obj"))
  assert_false(safe_asset_path("https://example.org/mesh.obj"))
  let sha = fixture().model.sha256
  validate_geometry({ "kind": "mesh", "asset": sha + ".obj", "sha256": sha })
  try
    validate_geometry({ "kind": "mesh", "asset": "mesh.obj", "sha256": sha })
  catch {
    _ => ()
  } noraise {
    _ => fail("non-content-addressed asset accepted")
  }
}
