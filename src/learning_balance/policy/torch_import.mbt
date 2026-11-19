///|
struct GeometrySpec {
  joint_names : Array[String]
  bodies : Array[@balance.Body]
  feet : Array[@balance.Foot]
} derive(FromJson)

///|
fn number(value : @artifacts.TorchValue) -> Double raise {
  let n : Double = @json.from_json(value.plain_json())
  guard @numeric.finite(n) else { fail("nonfinite balance specification") }
  n
}

///|
fn tensor_vector(
  weights : @artifacts.TorchValue,
  name : String,
  width : Int32,
) -> Array[Double] raise {
  let t = weights.field(name).tensor()
  guard t.shape == [width] &&
    t.values.length() == width &&
    t.values.all(fn(v) { v == v }) else {
    fail("legacy balance vector shape differs: " + name)
  }
  t.values.copy()
}

///|
fn tensor_matrix(
  weights : @artifacts.TorchValue,
  name : String,
  rows : Int32,
  columns : Int32,
) -> Array[Array[Double]] raise {
  let t = weights.field(name).tensor()
  guard t.shape == [rows, columns] &&
    t.values.length() == rows * columns &&
    t.values.all(@numeric.finite) else {
    fail("legacy balance matrix shape differs: " + name)
  }
  Array::makei(rows, fn(i) {
    Array::makei(columns, fn(j) { t.values[i * columns + j] })
  })
}

///|
fn tensor_scalar(
  weights : @artifacts.TorchValue,
  name : String,
) -> Double raise {
  let t = weights.field(name).tensor()
  guard t.shape.is_empty() &&
    t.values.length() == 1 &&
    t.values[0] == t.values[0] else {
    fail("legacy balance scalar shape differs: " + name)
  }
  t.values[0]
}

///|
fn load_ankle(
  head : @balance.LearnedAnkleHead,
  weights : @artifacts.TorchValue,
  prefix : String,
) -> @balance.LearnedAnkleHead raise {
  let dimensions = if head.pose_rate { 5 } else { 3 }
  let mean = tensor_matrix(weights, prefix + "mean", 4, dimensions)
  let scale = tensor_matrix(weights, prefix + "scale", 4, dimensions)
  guard scale.all(fn(row) { row.all(fn(v) { v > 0.0 }) }) else {
    fail("invalid legacy balance normalization")
  }
  {
    ..head,
    lower: tensor_vector(weights, prefix + "lower", 4),
    upper: tensor_vector(weights, prefix + "upper", 4),
    mean,
    scale,
    weight: tensor_matrix(weights, prefix + "weight", 4, dimensions + 1),
  }
}

///|
/// Import a complete legacy v1/v2 feedback bundle, preserving the embedded frozen temporal parent and static geometry. Action-mapping versions are checked explicitly.
pub fn from_torch_payload(
  payload : @artifacts.TorchValue,
  sustained : Bool,
) -> BalancePolicy raise {
  let expected = if sustained {
    "moonrobo.g1-learned-balance-actor.v2"
  } else {
    "moonrobo.g1-learned-balance-actor.v1"
  }
  guard payload.field("format").plain_json() == expected.to_json() else {
    fail("legacy balance action-mapping format differs")
  }
  let parent = @temporal.temporal_from_torch_payload(payload.field("parent"))
  let spec : GeometrySpec = @json.from_json(
    payload.field("kinematics").plain_json(),
  )
  let geometry : @balance.Kinematics = {
    nu: spec.joint_names.length(),
    bodies: spec.bodies,
    feet: spec.feet,
  }
  let weights = payload.field("head")
  let head : @balance.FeedbackHead = if sustained {
    let head_spec = payload.field("head_spec")
    let pose_rate : Bool = @json.from_json(
      head_spec.field("pose_rate").plain_json(),
    )
    let control_waist : Bool = @json.from_json(
      head_spec.field("control_waist").plain_json(),
    )
    let base = @balance.SustainedBalanceHead::new(
      spec.joint_names,
      parent.base.lower,
      parent.base.upper,
      pose_rate~,
      control_waist~,
      output_bound=number(head_spec.field("output_bound")),
      fit_bound=number(head_spec.field("fit_bound")),
    )
    let ankle = load_ankle(base.ankle, weights, "ankle.")
    let waist_mean = tensor_vector(weights, "waist_mean", 2)
    let waist_scale = tensor_vector(weights, "waist_scale", 2)
    guard waist_scale.all(fn(v) { v > 0.0 }) else {
      fail("invalid waist normalization")
    }
    Sustained({
      ..base,
      ankle,
      waist_lower: tensor_scalar(weights, "waist_lower"),
      waist_upper: tensor_scalar(weights, "waist_upper"),
      waist_mean,
      waist_scale,
      waist_weight: tensor_vector(weights, "waist_weight", 3),
    })
  } else {
    let base = @balance.LearnedAnkleHead::new(
      spec.joint_names,
      parent.base.lower,
      parent.base.upper,
      bound=number(payload.field("residual_bound_rad")),
    )
    Learned(load_ankle(base, weights, ""))
  }
  let dt = number(payload.field("dt_s"))
  let window : Int32? = @json.from_json(payload.field("window").plain_json())
  guard dt > 0.0 &&
    geometry.nu == parent.base.lower.length() &&
    (match window {
      Some(n) => n > 0
      None => true
    }) else {
    fail("invalid legacy feedback observer specification")
  }
  { parent, head, geometry, dt, window, }
}

///|
pub async fn load_torch(
  path : String,
  sustained~ : Bool = false,
  expected_sha256? : String,
) -> (BalancePolicy, @artifacts.TorchValue) {
  let payload = @artifacts.load_torch_checkpoint(path, expected_sha256?)
  (from_torch_payload(payload, sustained), payload)
}
