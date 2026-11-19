///|
/// Actual derivative.eff_prec inputs: qH factors belong to mixed_module;
/// rhs/res, model block factors and sticky failure belong to views. `res` is
/// normally the Newton planner's ctx_Mgrad view. No inverse is synthesized.
pub(all) struct PreconditionerPlan {
  request : Request
  module_name : String
  mixed_module : String
  mixed_request : @sparse_solver.Request?
  views : Map[String, Json]
  mixed_views : Map[String, Json]
  efm0_active : Bool
  folded_blocks : Bool
  fold_contact : Bool
} derive(FromJson)

///|
pub extend PreconditionerPlan with @json.FromJson::{from_json}

///|
fn metric_launch(
  c : PreconditionerPlan,
  key : String,
  overrides : Map[String, Json],
) -> Json raise {
  guard c.request.kernels.contains(key) else {
    fail("preconditioner requires compiled helper: " + key)
  }
  let arguments : Map[String, Json] = Map([])
  for p in params(c.request, key) {
    let value = match overrides.get(p.name) {
      Some(v) => v
      None =>
        match c.views.get(p.name) {
          Some(v) => v
          None => fail("missing effective preconditioner view: " + p.name)
        }
    }
    arguments[p.name] = value
  }
  {
    "operation": "launch",
    "parameters": {
      "module": Json(c.module_name),
      "entry": Json(key),
      "arguments": Json(arguments),
    },
  }
}

///|
fn view_owner(value : Json) -> String raise {
  guard value is Object(fields) &&
    fields.get("buffer") is Some(String(name)) &&
    !name.is_empty() else {
    fail("actual owned pipeline view required")
  }
  name
}

///|
priv struct PlannedView {
  buffer : String
  dtype : String
  shape : Array[Int32]
  byte_strides : Array[Int32]
  offset_bytes : UInt64
} derive(FromJson)

///|
/// Actual eff_actuation qH lifecycle AFTER real coefficients are available:
/// copy M, add diagonal/tendon/actuator/fluid terms, factor the true packed qH.
/// This never computes actuator/passive coefficients from made-up constants.
pub fn backbone_factor_plan(
  c : PreconditionerPlan,
  include_fluid~ : Bool,
) -> Array[Json] raise {
  let r = c.request
  validate(r)
  guard !r.check_skip &&
    !c.module_name.is_empty() &&
    c.mixed_request is Some(mr) &&
    !c.mixed_module.is_empty() &&
    c.mixed_module != c.module_name &&
    mr.dtype == "float32" &&
    mr.nworld == r.nworld &&
    mr.architecture == r.architecture &&
    !mr.check_done else {
    fail("top-level qH construction requires matching unskipped real solver")
  }
  let lowered = @sparse_solver.lower(mr)
  guard lowered.nv == r.nv &&
    lowered.nC == r.nC &&
    c.views.get("M") is Some(m) &&
    c.views.get("qH") is Some(qh) else {
    fail("actual packed M/qH views and layout required")
  }
  let source : PlannedView = @json.from_json(m)
  let destination : PlannedView = @json.from_json(qh)
  let shape = [r.nworld, r.nC]
  let strides = [4 * r.nC, 4]
  guard !source.buffer.is_empty() &&
    !destination.buffer.is_empty() &&
    source.buffer != destination.buffer &&
    source.dtype == "float32" &&
    destination.dtype == "float32" &&
    source.shape == shape &&
    destination.shape == shape &&
    source.byte_strides == strides &&
    destination.byte_strides == strides &&
    source.offset_bytes % 4UL == 0UL &&
    destination.offset_bytes % 4UL == 0UL &&
    r.nworld <= 268435456 / 4 / r.nC else {
    fail("qH copy requires independent contiguous bounded FP32 owners")
  }
  let program : Array[Json] = [
    {
      "operation": "copy",
      "parameters": {
        "source": Json(source.buffer),
        "source_offset": Json(source.offset_bytes),
        "destination": Json(destination.buffer),
        "destination_offset": Json(destination.offset_bytes),
        "count_bytes": Json(r.nworld.to_uint64() * r.nC.to_uint64() * 4UL),
      },
    },
  ]
  program.push(metric_launch(c, "add-qh-diag", Map([])))
  if r.ntendon > 0 {
    program.push(metric_launch(c, "add-tendon-qh-diag", Map([])))
  }
  if r.nactuator > 0 {
    program.push(metric_launch(c, "add-actuator-qh-diag", Map([])))
  }
  if include_fluid {
    program.push(metric_launch(c, "add-fluid-qh", Map([])))
  }
  guard c.views.get("failure") is Some(failure) else {
    fail("actual shared failure owner required")
  }
  let arguments = c.mixed_views.copy()
  arguments["matrix"] = qh
  arguments["failure"] = failure
  let selected : Map[String, Json] = Map([])
  for e in lowered.entries {
    if e.key == "mixed-factor" {
      for p in e.parameters {
        guard arguments.get(p.name) is Some(value) else {
          fail("missing actual mixed qH factor view: " + p.name)
        }
        selected[p.name] = value
      }
    }
  }
  program.push({
    "operation": "launch",
    "parameters": {
      "module": Json(c.mixed_module),
      "entry": "mixed-factor",
      "arguments": Json(selected),
    },
  })
  program
}

///|
/// Exact source branch and order: optional backbone mask/solve, then efm0 or
/// independent 3x3 solve, then sleep zeroing. The returned program may be used
/// by newton_solver.plan_with_preconditioner at initialization AND each CG step.
pub fn preconditioner_plan(c : PreconditionerPlan) -> Array[Json] raise {
  let r = c.request
  validate(r)
  guard !c.module_name.is_empty() &&
    (!c.efm0_active || r.nefm0 > 0) &&
    !(c.efm0_active && c.folded_blocks) &&
    (!c.fold_contact || c.folded_blocks) else {
    fail("actual preconditioner branch metadata required")
  }
  let program : Array[Json] = []
  if c.folded_blocks {
    guard r.nblock > 0 else { fail("folded branch requires actual 3x3 blocks") }
    guard c.views.get("rhs") is Some(original_rhs) &&
      c.views.get("epB") is Some(blocks) &&
      c.views.get("epL") is Some(factors) &&
      view_owner(original_rhs) != view_owner(blocks) &&
      view_owner(original_rhs) != view_owner(factors) else {
      fail(
        "folded block construction must preserve original rhs in a distinct owner",
      )
    }
    program.push(metric_launch(c, "build-blocks", Map([])))
    if r.ntendon > 0 {
      program.push(metric_launch(c, "fold-tendon", Map([])))
    }
    if r.nactuator > 0 {
      program.push(metric_launch(c, "fold-actuator", Map([])))
    }
    if r.sparse_jacobian && r.njmax > 0 {
      program.push(metric_launch(c, "fold-efc-sparse", Map([])))
    }
    if c.fold_contact {
      program.push(metric_launch(c, "fold-contact-rank1", Map([])))
    }
    program.push(metric_launch(c, "factor-folded-blocks", Map([])))
  }
  let backbone = if c.efm0_active {
    r.nefm0 < r.nv
  } else {
    3 * r.nblock != r.nv
  }
  if backbone {
    guard c.views.get("rhs") is Some(original_rhs) &&
      c.views.get("res") is Some(result) &&
      view_owner(original_rhs) != view_owner(result) else {
      fail(
        "composite backbone preconditioner must retain original rhs in a distinct owner",
      )
    }
    guard c.mixed_request is Some(mr) &&
      !c.mixed_module.is_empty() &&
      c.mixed_module != c.module_name &&
      mr.dtype == "float32" &&
      mr.nworld == r.nworld &&
      mr.architecture == r.architecture &&
      mr.check_done == r.check_skip else {
      fail("backbone requires matching real mixed qH solver request")
    }
    let lowered = @sparse_solver.lower(mr)
    guard lowered.nv == r.nv && lowered.nC == r.nC else {
      fail("backbone qH layout differs")
    }
    program.push(metric_launch(c, "copy-backbone-rhs", Map([])))
    guard c.views.get("res") is Some(res) &&
      c.views.get("failure") is Some(failure) else {
      fail("actual res/failure views required")
    }
    let arguments = c.mixed_views.copy()
    arguments["rhs"] = res
    arguments["solution"] = res
    arguments["failure"] = failure
    if mr.check_done {
      guard c.views.get("skip") is Some(skip) else {
        fail("actual shared done view required")
      }
      arguments["done"] = skip
    }
    let selected : Map[String, Json] = Map([])
    for e in lowered.entries {
      if e.key == "mixed-solve" {
        for p in e.parameters {
          guard arguments.get(p.name) is Some(value) else {
            fail("missing mixed qH factor view: " + p.name)
          }
          selected[p.name] = value
        }
      }
    }
    program.push({
      "operation": "launch",
      "parameters": {
        "module": Json(c.mixed_module),
        "entry": "mixed-solve",
        "arguments": Json(selected),
      },
    })
  }
  if c.efm0_active {
    program.push(metric_launch(c, "efm0-solve", Map([])))
  } else if r.nblock > 0 {
    let overrides : Map[String, Json] = Map([])
    if c.folded_blocks {
      guard c.views.get("epL") is Some(factor) else {
        fail("actual folded epL view required")
      }
      overrides["efm_L"] = factor
    }
    program.push(metric_launch(c, "block-solve", overrides))
  }
  if r.sleep {
    program.push(metric_launch(c, "zero-sleeping", Map([])))
  }
  program
}
