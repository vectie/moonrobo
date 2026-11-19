///|
fn only_fields(
  value : Json,
  names : Array[String],
  location : String,
) -> Map[String, Json] raise ConvergenceError {
  guard value is Object(fields) else {
    raise Invalid(location + " must be an object")
  }
  for key in fields.keys() {
    guard names.contains(key) else {
      raise Unsupported(location + " contains unsupported field: " + key)
    }
  }
  fields
}

///|
fn validate_command(request : CommandRequest) -> Unit raise ConvergenceError {
  let ray = request.operation == "linesearch"
  guard ray || request.operation == "convergence" else {
    raise Unsupported(
      "unknown convergence fragment operation: " + request.operation,
    )
  }
  let root = only_fields(
    request.parameters,
    if ray {
      ["nv", "njmax", "ls_iterations", "incremental", "worlds"]
    } else {
      ["mode", "nv", "iterations", "nsolving", "worlds"]
    },
    "parameters",
  )
  guard root.get("worlds") is Some(Array(worlds)) else {
    raise Invalid("parameters.worlds must be an array")
  }
  for value in worlds {
    let fields = only_fields(
      value,
      if ray {
        [
          "done", "tolerance", "ls_tolerance", "meaninertia", "ne", "nf", "rows",
          "qacc", "ma", "qfrc_smooth", "search", "mv", "search_dot", "alpha", "improvement",
          "ls_exhausted", "overflow",
        ]
      } else {
        [
          "done", "solver_niter", "overflow", "alpha", "improvement", "grad_dot",
          "newton_decrement", "tolerance", "meaninertia", "beta", "cg",
        ]
      },
      "world",
    )
    if ray {
      guard fields.get("rows") is Some(Array(rows)) else {
        raise Invalid("ray rows must be an array")
      }
      for row in rows {
        ignore(
          only_fields(
            row,
            ["jaref", "jv", "diagonal", "frictionloss"],
            "ray row",
          ),
        )
      }
    } else if fields.get("cg") is Some(cg) && cg != Json::null() {
      ignore(
        only_fields(
          cg,
          ["grad", "mgrad", "previous_grad", "previous_mgrad"],
          "CG vectors",
        ),
      )
    }
  }
}

///|
/// Explicit JSON entry point for actual CPU/Double calculations on supplied
/// solver state. It does not load an SDK, assemble a model or run a full solver.
pub fn prepare(request : CommandRequest) -> Json raise {
  validate_command(request)
  let result = match request.operation {
    "linesearch" => linesearch(@json.from_json(request.parameters)).to_json()
    "convergence" => convergence(@json.from_json(request.parameters)).to_json()
    _ =>
      raise Unsupported(
        "unknown convergence fragment operation: " + request.operation,
      )
  }
  {
    "format": "moonrobo-host-convergence-fragment-v1",
    "operation": request.operation.to_json(),
    "result": result,
    "numeric_backend": "CPU/Double",
    "mujoco_warp_version": "3.15.0",
    "solver_source_sha256": "d26300bbe665aa182a0afc30c3d1ee43c38b8b14841e2e61544c92dea97af916",
    "math_source_sha256": "d08e978993c3d3b5d3f16cb96af94beff519a60a5ea827134b388f30c3a6756c",
    "types_source_sha256": "5ff63b8186bafba2e2d51d5aae84875fb289411d9984f4e06b51813ea088491b",
    "cone": "pyramidal",
    "full_solver_closure": false,
    "device_state_modified": false,
    "runtime_equivalence_verified": false,
  }
}
