///|
fn expect_shape(call : Call, name : String, shape : Array[Int32]) -> Unit raise {
  guard call.named[name].shape == shape else {
    fail("concrete specialization shape differs: " + name)
  }
}

///|
/// Read a component of a compound int32 element after full span validation.
fn component_i32(
  view : View,
  buffers : Map[String, HostBuffer],
  index : Int32,
  component : Int32,
) -> Int32 raise {
  guard view.dtype == "vec2i" &&
    index >= 0 &&
    index < view.shape[0] &&
    component >= 0 &&
    component < 2 else {
    fail("invalid vec2i metadata read")
  }
  let offset = view.offset_bytes.to_int() +
    index * view.byte_strides[0] +
    component * 4
  let bytes = buffers[view.buffer].bytes
  (bytes[offset].to_uint() |
  (bytes[offset + 1].to_uint() << 8) |
  (bytes[offset + 2].to_uint() << 16) |
  (bytes[offset + 3].to_uint() << 24)).reinterpret_as_int()
}

///|
fn index_owner(view : View, immutable : Map[String, Unit]) -> Unit {
  immutable[view.buffer] = ()
}

///|
fn validate_g1(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let r : @kernels.SpecializationRequest = @json.from_json(module.request)
  let bodies = call.entry.key == "publish-body-state" ||
    call.entry.key == "publish-body-pose" ||
    call.entry.key == "publish-body-velocity"
  for param in call.entry.parameters {
    if param.kind == "array" {
      let view = call.named[param.name]
      let shape = if param.rank == 2 {
        [
          r.num_envs,
          if bodies || param.name == "body_acc_w" {
            r.num_bodies
          } else {
            r.num_joints
          },
        ]
      } else if param.rank == 1 {
        [
          if param.name == "env_mask" {
            r.num_envs
          } else if [
              "user_mask", "joint_mask", "joint_modes", "joint_indices", "backend_to_user",
            ].contains(param.name) {
            r.num_joints
          } else if param.name == "user_to_backend" ||
            param.name == "dst_to_src" {
            if bodies {
              r.num_bodies
            } else {
              r.num_joints
            }
          } else {
            r.num_envs
          },
        ]
      } else {
        fail("unsupported G1 array rank")
      }
      expect_shape(call, param.name, shape)
      if ["user_to_backend", "backend_to_user", "dst_to_src", "joint_indices"].contains(
          param.name,
        ) {
        let seen : Map[Int32, Unit] = {}
        for i in 0..<shape[0] {
          let value = scalar_i32(view, buffers, [i])
          guard value >= 0 && value < shape[0] && !seen.contains(value) else {
            fail(
              "G1 gather/scatter indices must be an actual bounded permutation",
            )
          }
          seen[value] = ()
        }
        index_owner(view, immutable)
      }
    }
  }
}

///|
fn scalar_argument(call : Call, name : String) -> Int32 raise {
  for i, param in call.entry.parameters {
    if param.name == name {
      guard call.arguments[i] is Int32(value) else {
        fail("required int32 scalar argument missing")
      }
      return value
    }
  }
  fail("scalar argument absent: " + name)
}

///|
fn validate_physics(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  let r : @physics_kernels.Request = @json.from_json(module.request)
  let w = r.nworld
  let nv = r.nv
  match call.entry.key {
    "mass-multiply-sparse" => {
      expect_shape(call, "M_mulm_rowadr", [nv + 1])
      expect_shape(call, "M_in", [w, r.mass_nnz])
      expect_shape(call, "vec", [w, nv])
      expect_shape(call, "res", [w, nv])
      expect_shape(call, "skip", [w])
      let adr = call.named["M_mulm_rowadr"]
      let col = call.named["M_mulm_col"]
      let madr = call.named["M_mulm_madr"]
      guard col.shape == madr.shape && scalar_i32(adr, buffers, [0]) == 0 else {
        fail("sparse gather metadata cardinality/start differs")
      }
      let count = col.shape[0]
      let mut previous = 0
      for i in 1..<=nv {
        let next = scalar_i32(adr, buffers, [i])
        guard next >= previous && next <= count else {
          fail("invalid sparse gather row interval")
        }
        previous = next
      }
      guard previous == count else {
        fail("sparse gather row intervals do not consume all entries")
      }
      for i in 0..<count {
        let c = scalar_i32(col, buffers, [i])
        let m = scalar_i32(madr, buffers, [i])
        guard c >= 0 && c < nv && m >= 0 && m < r.mass_nnz else {
          fail("actual sparse gather index exceeds vector/matrix bounds")
        }
      }
      for view in [adr, col, madr] {
        index_owner(view, immutable)
      }
    }
    "constraint-force-zero-sparse" => {
      expect_shape(call, "state_changed_count_in", [w])
      expect_shape(call, "ctx_done_in", [w])
      expect_shape(call, "qfrc_constraint_out", [w, nv])
    }
    "constraint-force-rebuild-sparse" => {
      for name in ["nefc_in", "state_changed_count_in", "ctx_done_in"] {
        expect_shape(call, name, [w])
      }
      for name in ["efc_J_rownnz_in", "efc_J_rowadr_in", "efc_force_in"] {
        expect_shape(call, name, [w, r.njmax])
      }
      for name in ["efc_J_colind_in", "efc_J_in"] {
        expect_shape(call, name, [w, 1, r.jacobian_capacity])
      }
      expect_shape(call, "dof_cdof_in", [w, nv])
      expect_shape(call, "qfrc_constraint_out", [w, nv])
      for world in 0..<w {
        let count = scalar_i32(call.named["nefc_in"], buffers, [world])
        guard count >= 0 && count <= r.njmax else {
          fail("actual nefc exceeds specialized CSR row capacity")
        }
        for row in 0..<count {
          let size = scalar_i32(call.named["efc_J_rownnz_in"], buffers, [
            world, row,
          ])
          let start = scalar_i32(call.named["efc_J_rowadr_in"], buffers, [
            world, row,
          ])
          guard size >= 0 &&
            start >= 0 &&
            start <= r.jacobian_capacity &&
            size <= r.jacobian_capacity - start else {
            fail("actual constraint CSR interval exceeds capacity")
          }
          for k in start..<(start + size) {
            let col = scalar_i32(call.named["efc_J_colind_in"], buffers, [
              world, 0, k,
            ])
            guard col >= 0 && col < nv else {
              fail("constraint CSR column exceeds DOF capacity")
            }
          }
        }
        if r.compact {
          for dof in 0..<nv {
            guard scalar_i32(call.named["dof_cdof_in"], buffers, [world, dof]) <
              nv else {
              fail("compact DOF mapping exceeds destination capacity")
            }
          }
        }
      }
      for
        name in [
          "nefc_in", "efc_J_rownnz_in", "efc_J_rowadr_in", "efc_J_colind_in", "dof_cdof_in",
        ] {
        index_owner(call.named[name], immutable)
      }
    }
    "nxn-broadphase" => {
      for name in ["geom_type", "geom_bodyid"] {
        expect_shape(call, name, [r.ngeom])
      }
      expect_shape(call, "geom_dataid", [r.ngeom_dataid, r.ngeom])
      expect_shape(call, "geom_aabb", [r.ngeom_aabb, r.ngeom, 2])
      for
        (name, batch) in [
          ("geom_rbound", r.ngeom_rbound),
          ("geom_margin", r.ngeom_margin),
          ("geom_gap", r.ngeom_gap),
        ] {
        expect_shape(call, name, [batch, r.ngeom])
      }
      for name in ["nxn_geom_pair", "nxn_pairid"] {
        expect_shape(call, name, [r.npair])
      }
      for name in ["geom_xpos_in", "geom_xmat_in"] {
        expect_shape(call, name, [w, r.ngeom])
      }
      expect_shape(call, "ncollision_out", [1])
      // sleep is rejected by the lowerer; awake descriptors are ABI inputs but
      // never indexed by this generated body.
      guard scalar_i32(call.named["ncollision_out"], buffers, [0]) == 0 else {
        fail("NXN profile requires initial zero candidate counter")
      }
      let cap = scalar_argument(call, "naconmax_in")
      guard cap >= w * r.npair else {
        fail(
          "NXN profile requires worst-case capacity, preventing truncated candidate publication",
        )
      }
      for
        name in [
          "collision_pair_out", "collision_pairid_out", "collision_worldid_out",
        ] {
        guard call.named[name].shape[0] >= cap else {
          fail("NXN actual output storage is smaller than naconmax")
        }
      }
      let pairs = call.named["nxn_geom_pair"]
      for i in 0..<r.npair {
        for component in 0..<2 {
          let geom = component_i32(pairs, buffers, i, component)
          guard geom >= 0 && geom < r.ngeom else {
            fail("NXN actual geom index exceeds all geom inputs")
          }
        }
      }
      index_owner(pairs, immutable)
    }
    _ => fail("unsupported concrete physics program")
  }
}

///|
fn validate_call(
  call : Call,
  module : Module,
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Unit raise {
  match module.kind {
    "moonrobo-g1-concrete-kernel-module-v1" => {
      validate_g1(call, module, buffers, immutable)
      if call.entry.parameters.any(p => p.name == "num_bodies") {
        let r : @kernels.SpecializationRequest = @json.from_json(module.request)
        guard scalar_argument(call, "num_bodies") == r.num_bodies else {
          fail("G1 scalar num_bodies differs from specialization")
        }
      }
    }
    "moonrobo-mjw-concrete-physics-module-v1" =>
      validate_physics(call, module, buffers, immutable)
    "moonrobo-native-primitive-contact-module-v1" => {
      let r : @narrowphase.Request = @json.from_json(module.request)
      let bindings = call.entry.parameters.map(fn(p) {
        let v = call.named[p.name]
        @narrowphase.Binding::{
          name: p.name,
          allocation: v.buffer,
          dtype: v.dtype,
          shape: v.shape,
          byte_strides: v.byte_strides,
          byte_offset: v.offset_bytes.to_int64(),
          buffer_bytes: buffers[v.buffer].bytes.length().to_int64(),
        }
      })
      @narrowphase.validate_bindings(r, bindings)
      guard scalar_i32(call.named["nacon_out"], buffers, [0]) == 0 &&
        scalar_i32(call.named["rejected_out"], buffers, [0]) == 0 &&
        scalar_i32(call.named["rejected_out"], buffers, [1]) == 0 else {
        fail("narrowphase requires initial zero contact/rejection counters")
      }
      guard r.candidate_capacity <= 2147483647 / 8 else {
        fail(
          "at most eight generated contacts per candidate must fit signed atomic counters",
        )
      }
    }
    "moonrobo-device-convergence-module-v1" =>
      validate_convergence(call, module, buffers, immutable)
    "moonrobo-native-convex-gjk-module-v1"
    | "moonrobo-mathdx-tile-module-v1"
    | "moonrobo-native-convex-contact-module-v1" =>
      validate_stage(call, module, buffers)
    "moonrobo-native-mixed-sparse-solver-module-v1"
    | "moonrobo-native-sparse-lu-module-v1" =>
      validate_sparse_solver(call, module, buffers, immutable)
    "moonrobo-native-newton-solver-module-v1" =>
      validate_newton_solver(call, module, buffers, immutable)
    "moonrobo-native-solver-metrics-module-v1" =>
      validate_solver_metrics(call, module, buffers, immutable)
    "moonrobo-native-solver-adapters-module-v1" =>
      validate_solver_adapters(call, module, buffers, immutable)
    _ => fail("unsupported module")
  }
}

///|
/// Counter owners are only written by their unique producer and zeros. This
/// retains the initial-zero proof even through earlier branches and copies.
fn protect_counters(
  program : Array[Op],
  protected : Map[String, String],
  collect : Bool,
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) => {
        let key = call.module + "::" + call.entry.key
        if collect {
          let names = if call.entry.key == "nxn-broadphase" {
            ["ncollision_out"]
          } else if call.entry.key == "contacts" ||
            call.entry.key == "convex-contacts" {
            ["nacon_out", "rejected_out"]
          } else {
            []
          }
          for name in names {
            let owner = call.named[name].buffer
            let producer = if name == "nacon_out" {
              "native-terminal-contact-stream"
            } else {
              key
            }
            guard !protected.contains(owner) ||
              (
                producer == "native-terminal-contact-stream" &&
                protected[owner] == producer
              ) else {
              fail("counter owners may not alias independent atomic producers")
            }
            protected[owner] = producer
          }
        } else {
          for param in call.entry.parameters {
            if param.kind == "array" && param.access != "input" {
              let owner = call.named[param.name].buffer
              if protected.get(owner) is Some(producer) {
                guard producer == key ||
                  (
                    producer == "native-terminal-contact-stream" &&
                    param.name == "nacon_out" &&
                    ["contacts", "convex-contacts"].contains(call.entry.key)
                  ) else {
                  fail("another kernel rewrites protected atomic counter owner")
                }
              }
            }
          }
        }
      }
      CopyBytes(copy) =>
        if !collect {
          guard !protected.contains(copy.destination) else {
            fail(
              "copy may not overwrite protected zero-initialized counter owner",
            )
          }
        }
      ZeroBytes(_) => ()
      If(_, yes, no) => {
        protect_counters(yes, protected, collect)
        protect_counters(no, protected, collect)
      }
      While(_, body) => protect_counters(body, protected, collect)
    }
  }
}
