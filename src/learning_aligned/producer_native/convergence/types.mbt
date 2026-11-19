///|
pub suberror ConvergenceError {
  Invalid(String)
  Unsupported(String)
} derive(Debug)

///|
/// Each row is an already assembled constraint ray. Equality rows precede
/// frictionloss rows; remaining rows are unilateral/pyramidal constraints.
pub(all) struct RayRow {
  jaref : Double
  jv : Double
  diagonal : Double
  frictionloss : Double
} derive(Debug, FromJson, ToJson)

///|
/// Existing outputs are supplied explicitly so done worlds and nonincremental
/// ls_exhausted retain their previous values exactly.
pub(all) struct RayWorld {
  done : Bool
  tolerance : Double
  ls_tolerance : Double
  meaninertia : Double
  ne : Int32
  nf : Int32
  rows : Array[RayRow]
  qacc : Array[Double]
  ma : Array[Double]
  qfrc_smooth : Array[Double]
  search : Array[Double]
  mv : Array[Double]
  search_dot : Double
  alpha : Double
  improvement : Double
  ls_exhausted : Bool
  overflow : Int32
} derive(Debug, FromJson, ToJson)

///|
/// Supported cone is fixed pyramidal. Matrix/Jacobian products and ray rows
/// must be actual supplied values; this package does not assemble them.
pub(all) struct LineSearchRequest {
  nv : Int32
  njmax : Int32
  ls_iterations : Int32
  incremental : Bool
  worlds : Array[RayWorld]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct LineSearchWorld {
  state : RayWorld
  iterations_used : Int32
  converged : Bool
  skipped_done : Bool
} derive(Debug, ToJson)

///|
pub(all) struct CgVectors {
  grad : Array[Double]
  mgrad : Array[Double]
  previous_grad : Array[Double]
  previous_mgrad : Array[Double]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct ConvergenceWorld {
  done : Bool
  solver_niter : Int32
  overflow : Int32
  alpha : Double
  improvement : Double
  grad_dot : Double
  newton_decrement : Double
  tolerance : Double
  meaninertia : Double
  beta : Double
  cg : CgVectors?
} derive(Debug, FromJson, ToJson)

///|
/// nsolving must equal the count of unfinished worlds. This is the actual
/// device-loop condition equivalent, never a manufactured fixed-repeat count.
pub(all) struct ConvergenceRequest {
  mode : String
  nv : Int32
  iterations : Int32
  nsolving : Int32
  worlds : Array[ConvergenceWorld]
} derive(Debug, FromJson, ToJson)

///|
pub(all) struct ConvergenceResult {
  worlds : Array[ConvergenceWorld]
  nsolving : Int32
  continue_condition : Bool
} derive(Debug, ToJson)

///|
pub(all) struct CommandRequest {
  operation : String
  parameters : Json
} derive(Debug, FromJson, ToJson)

///|
fn finite(x : Double) -> Bool {
  !x.is_nan() && !x.is_inf()
}

///|
fn valid(values : Array[Double]) -> Bool {
  values.all(finite)
}

///|
/// Matches mujoco_warp.math.safe_div with MuJoCo mjMINVAL=1e-15. The guard
/// replaces only an exactly zero denominator, not every small denominator.
fn safe_div(x : Double, y : Double) -> Double {
  x / (if y != 0.0 { y } else { 1.0e-15 })
}

///|
fn checked(x : Double) -> Double raise ConvergenceError {
  guard finite(x) else {
    raise Invalid("CPU/Double convergence arithmetic became nonfinite")
  }
  x
}

///|
fn point(
  cost : Double,
  grad : Double,
  hessian : Double,
) -> @geometry.Vec3 raise ConvergenceError {
  @geometry.vec3(checked(cost), checked(grad), checked(hessian))
}

///|
fn add(
  a : @geometry.Vec3,
  b : @geometry.Vec3,
) -> @geometry.Vec3 raise ConvergenceError {
  point(a.x + b.x, a.y + b.y, a.z + b.z)
}
