///|
/// Pending metadata-only regressions. No test is executed in this migration.
fn rejects(work : () -> Unit raise) -> Bool {
  try {
    work()
    false
  } catch {
    _ => true
  }
}

///|
test "finalizer tags preserve primitive ABI without float conversion" {
  for
    (tag, expected) in [
      ("i32", "int32"),
      ("i64", "int64"),
      ("u64", "uint64"),
      ("f32", "float32"),
      ("f64", "float64"),
      ("bool", "bool"),
    ] {
    assert_eq(host_scalar_type(tag), expected)
  }
  assert_true(rejects(fn() { ignore(host_scalar_type("f16")) }))
}

///|
test "full compound span and self alias are independent proofs" {
  let buffers : Map[String, HostBuffer] = {
    "pose": { name: "pose", scalar_type: "float32", bytes: Bytes::make(56, 0), },
  }
  let packed : View = {
    buffer: "pose",
    dtype: "transformf",
    shape: [2],
    byte_strides: [28],
    offset_bytes: 0UL,
  }
  assert_eq(span(packed, buffers), (0UL, 56UL))
  writable(packed)
  assert_true(rejects(fn() { writable({ ..packed, byte_strides: [4], }) }))
  assert_true(
    rejects(fn() { ignore(span({ ..packed, offset_bytes: 4UL, }, buffers)) }),
  )
}

///|
test "index owner protection applies to nested copy and zero" {
  let immutable : Map[String, Unit] = { "indices": () }
  let copy : Copy = {
    source: "source",
    source_offset: 0UL,
    destination: "indices",
    destination_offset: 0UL,
    count_bytes: 4UL,
  }
  let predicate : View = {
    buffer: "predicate",
    dtype: "int32",
    shape: [1],
    byte_strides: [4],
    offset_bytes: 0UL,
  }
  assert_true(
    rejects(fn() {
      validate_writes([If(predicate, [CopyBytes(copy)], [])], immutable)
    }),
  )
  assert_true(
    rejects(fn() {
      validate_writes(
        [ZeroBytes({ buffer: "indices", offset_bytes: 0UL, count_bytes: 4UL, })],
        immutable,
      )
    }),
  )
}

///|
test "protected atomic counters reject copy even in conditional branch" {
  let protected : Map[String, String] = { "count": "module::contacts" }
  let copy : Copy = {
    source: "source",
    source_offset: 0UL,
    destination: "count",
    destination_offset: 0UL,
    count_bytes: 4UL,
  }
  assert_true(
    rejects(fn() { protect_counters([CopyBytes(copy)], protected, false) }),
  )
  protect_counters(
    [ZeroBytes({ buffer: "count", offset_bytes: 0UL, count_bytes: 4UL, })],
    protected,
    false,
  )
}

///|
test "nested predicate objects reject unknown keys before CUDA setup" {
  let commands : Json = [
    {
      "operation": "if",
      "parameters": {
        "condition": {
          "buffer": "p",
          "dtype": "int32",
          "shape": [1],
          "byte_strides": [4],
          "offset_bytes": 0,
          "unexpected": true,
        },
        "on_true": [],
        "on_false": [],
      },
    },
  ]
  assert_true(rejects(fn() { check_commands(commands, 0, Ref(0)) }))
}

///|
test "CPU Double seed packing retains signed zero raw bits" {
  let buffer = packed_double_buffer("seed", [[1.0, -0.0]])
  assert_eq(buffer.scalar_type, "float64")
  assert_eq(
    buffer.bytes,
    b"\x00\x00\x00\x00\x00\x00\xf0\x3f\x00\x00\x00\x00\x00\x00\x00\x80",
  )
}

///|
test "device convergence control proof rejects zero and copy through branches" {
  let protected : Map[String, String] = { "nsolving": "solver::newton-done" }
  let modules : Map[String, Module] = {}
  let predicate : View = {
    buffer: "nsolving",
    dtype: "int32",
    shape: [1],
    byte_strides: [4],
    offset_bytes: 0UL,
  }
  let zero = ZeroBytes({
    buffer: "nsolving",
    offset_bytes: 0UL,
    count_bytes: 4UL,
  })
  assert_true(
    rejects(fn() {
      protect_convergence(
        [If(predicate, [zero], [])],
        modules,
        protected,
        [],
        false,
      )
    }),
  )
  let copy = CopyBytes({
    source: "other",
    source_offset: 0UL,
    destination: "nsolving",
    destination_offset: 0UL,
    count_bytes: 4UL,
  })
  assert_true(
    rejects(fn() {
      protect_convergence(
        [While(predicate, [copy])],
        modules,
        protected,
        [],
        false,
      )
    }),
  )
}

///|
test "MathDx and convex publication gates cannot be zeroed afterward" {
  let protected : Map[String, String] = { "status": "tile::mathdx-tile-factor" }
  assert_true(
    rejects(fn() {
      protect_stages(
        [ZeroBytes({ buffer: "status", offset_bytes: 0UL, count_bytes: 4UL, })],
        {},
        protected,
        [],
        Ref(None),
        false,
      )
    }),
  )
}

///|
test "solver failure cannot be cleared or copied inside a captured branch" {
  let view : View = {
    buffer: "failure",
    dtype: "int32",
    shape: [1],
    byte_strides: [4],
    offset_bytes: 0UL,
  }
  let protected : Map[String, StickyStatus] = {
    "failure": { module: "solver", view, },
  }
  assert_true(
    rejects(fn() {
      protect_solver_status(
        [
          While(view, [
            ZeroBytes({
              buffer: "failure",
              offset_bytes: 0UL,
              count_bytes: 4UL,
            }),
          ]),
        ],
        {},
        {},
        protected,
        false,
      )
    }),
  )
  assert_true(
    rejects(fn() {
      protect_solver_status(
        [
          If(view, [], [
            CopyBytes({
              source: "other",
              source_offset: 0UL,
              destination: "failure",
              destination_offset: 0UL,
              count_bytes: 4UL,
            }),
          ]),
        ],
        {},
        {},
        protected,
        false,
      )
    }),
  )
}

///|
test "metadata snapshot gathers actual strided bytes without conversion" {
  let buffers : Map[String, HostBuffer] = {
    "indices": {
      name: "indices",
      scalar_type: "int32",
      bytes: Bytes::makei(32, i => i.to_byte()),
    },
  }
  let view : View = {
    buffer: "indices",
    dtype: "int32",
    shape: [2, 2],
    byte_strides: [16, 4],
    offset_bytes: 4UL,
  }
  assert_eq(
    packed_view(view, buffers),
    b"\x04\x05\x06\x07\x08\x09\x0a\x0b\x14\x15\x16\x17\x18\x19\x1a\x1b",
  )
}

///|
test "zero DOF descriptors have no reachable data or writable alias" {
  let buffers : Map[String, HostBuffer] = {
    "abi": { name: "abi", scalar_type: "float32", bytes: b"\x00\x00\x00\x00", },
  }
  let view : View = {
    buffer: "abi",
    dtype: "float32",
    shape: [3, 0],
    byte_strides: [4, 4],
    offset_bytes: 4UL,
  }
  assert_eq(span(view, buffers), (4UL, 4UL))
  assert_eq(packed_view(view, buffers), b"")
  writable(view)
}
