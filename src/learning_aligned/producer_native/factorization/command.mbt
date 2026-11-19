///|
fn object_fields(
  value : Json,
  allowed : Array[String],
  location : String,
) -> Map[String, Json] raise FactorizationError {
  guard value is Object(fields) else {
    raise Invalid(location + " must be an object")
  }
  for key in fields.keys() {
    guard allowed.contains(key) else {
      raise Unsupported(location + " contains an unsupported field: " + key)
    }
  }
  fields
}

///|
fn normalize_parameters(
  value : Json,
  blocks : Bool,
  mixed~ : Bool = false,
) -> Json raise FactorizationError {
  let allowed = ["layout", "matrix", "rhs", "regularization", "skip_worlds"]
  if blocks {
    allowed.push("factor_seed")
    allowed.push("inverse_diagonal_seed")
  }
  let fields = object_fields(value, allowed, "factorization parameters")
  guard fields.get("layout") is Some(raw_layout) else {
    raise Invalid("layout is required")
  }
  let layout_fields = [
    "M_rownnz", "M_rowadr", "M_colind", "m_rownnz", "m_rowadr", "m_colind", "qLD_block_adr",
    "qLD_block_total",
  ]
  layout_fields.push(if blocks { "blocks" } else { "dof_parentid" })
  if mixed {
    layout_fields.push("dof_parentid")
    layout_fields.push("tree_dofadr")
    layout_fields.push("tree_dofnum")
  }
  let original = object_fields(raw_layout, layout_fields, "layout")
  let layout : Map[String, Json] = Map([])
  for key, item in original {
    let name = match key {
      "M_rownnz" => "m_rownnz"
      "M_rowadr" => "m_rowadr"
      "M_colind" => "m_colind"
      _ => key
    }
    guard layout.get(name) is None else {
      raise Invalid("duplicate canonical/upstream layout field: " + name)
    }
    layout[name] = item
  }
  if blocks && layout.get("blocks") is Some(Array(values)) {
    for block in values {
      ignore(
        object_fields(
          block,
          if mixed {
            ["start", "size", "elemid"]
          } else {
            ["start", "size"]
          },
          "factor block",
        ),
      )
    }
  }
  let result : Map[String, Json] = Map([])
  for key, item in fields {
    result[key] = if key == "layout" { Json(layout) } else { item }
  }
  Json(result)
}

///|
/// Actual CPU/Double factorization and backsubstitution fragments. This never
/// initializes an SDK/device or substitutes for the complete MuJoCo solver.
pub fn execute(request : CommandRequest) -> Json raise {
  let solve = request.operation == "tree-factor-solve" ||
    request.operation == "small-block-factor-solve" ||
    request.operation == "mixed-factor-solve"
  let result : Json = match request.operation {
    "tree-factor" | "tree-factor-solve" => {
      let typed : TreeRequest = @json.from_json(
        normalize_parameters(request.parameters, false),
      )
      let factor = factor_tree(typed)
      let solution : Json = if solve {
        guard typed.rhs is Some(rhs) else {
          raise Invalid("factor-solve requires an actual RHS")
        }
        Json(factor.solve(rhs))
      } else {
        guard typed.rhs is None else {
          raise Invalid(
            "tree-factor does not silently discard a supplied RHS; choose tree-factor-solve",
          )
        }
        Json::null()
      }
      { "factor": factor.data(), "solution": solution }
    }
    "small-block-factor" | "small-block-factor-solve" => {
      let typed : BlockRequest = @json.from_json(
        normalize_parameters(request.parameters, true),
      )
      let factor = factor_small_blocks(typed)
      let solution : Json = if solve {
        guard typed.rhs is Some(rhs) else {
          raise Invalid("factor-solve requires an actual RHS")
        }
        Json(factor.solve(rhs))
      } else {
        guard typed.rhs is None else {
          raise Invalid(
            "small-block-factor does not silently discard a supplied RHS; choose small-block-factor-solve",
          )
        }
        Json::null()
      }
      { "factor": factor.data(), "solution": solution }
    }
    "mixed-factor" | "mixed-factor-solve" => {
      let typed : MixedRequest = @json.from_json(
        normalize_parameters(request.parameters, true, mixed=true),
      )
      let factor = factor_mixed(typed)
      let solution : Json = if solve {
        guard typed.rhs is Some(rhs) else {
          raise Invalid("factor-solve requires an actual RHS")
        }
        Json(factor.solve(rhs))
      } else {
        guard typed.rhs is None else {
          raise Invalid(
            "mixed-factor does not silently discard a supplied RHS; choose mixed-factor-solve",
          )
        }
        Json::null()
      }
      { "factor": factor.data(), "solution": solution }
    }
    _ =>
      raise Unsupported("unknown factorization fragment: " + request.operation)
  }
  {
    "format": "moonrobo-native-factorization-fragment-v1",
    "operation": Json(request.operation),
    "result": result,
    "numeric_backend": "CPU/Double",
    "mujoco_warp_version": "3.15.0",
    "source_smooth_sha256": "6268f0e1b6cb4c9ec6bbd3aa29828dfb36224efb2a3a3e1f54e5f87b6623fdef",
    "source_io_sha256": "2334b394e8f319f0fd2a2957240cdcc77a998513be11767a00f55f26ae07f4b0",
    "full_solver": false,
    "runtime_equivalence_verified": false,
    "device_state_modified": false,
    "regularization_added": false,
    "pivoting": false,
    "unsupported": Json(
      if request.operation == "mixed-factor" ||
        request.operation == "mixed-factor-solve" {
        [
          "arbitrary-CSR-fill-in", "sparse-nonancestor-prefix", "augmented-Cholesky-constraint-Newton",
          "nonzero-regularization", "skipped-worlds", "GPU-execution", "GPU-MathDx-tile-lowering",
        ]
      } else {
        [
          "arbitrary-CSR-fill-in", "mixed-block-sparse-closure", "tile-gather-augmented-Cholesky",
          "nonzero-regularization", "skipped-worlds", "GPU-execution",
        ]
      },
    ),
  }
}
