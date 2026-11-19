///|
/// Inputs contain only authored USD values, not composed schema fallbacks.
/// JSON strings "+inf" / "-inf" encode numeric schema sentinels explicitly.
pub(all) struct SchemaRequest {
  resolvers : Array[String]
  prim_type : String
  attributes : Map[String, Json]
  keys : Array[String]
  defaults : Map[String, Json]
} derive(FromJson, ToJson)

///|
pub(all) struct Joint {
  world : Int32
  linear_dofs : Int32
  angular_dofs : Int32
} derive(FromJson, ToJson)

///|
/// Newton body/joint indices and Newton xyz+xyzw relpose. None preserves the
/// public helper defaults; in particular a missing weld pose uses its sentinel.
pub(all) struct Equality {
  kind : String
  world : Int32
  body1 : Int32
  body2 : Int32
  joint1 : Int32
  joint2 : Int32
  anchor : Array[Double]?
  relpose : Array[Double]?
  torquescale : Double?
  polycoef : Array[Double]?
  label : String
  enabled : Bool
  solref : Array[Double]?
  solimp : Array[Double]?
} derive(FromJson, ToJson)

///|
/// Names are the caller's actual exported MuJoCo names, not inferred from USD
/// labels. Only pure equalities are supported; loop/mimic projections are not.
pub(all) struct EqualityRequest {
  world_count : Int32
  body_world : Array[Int32]
  body_names : Array[String]
  joints : Array[Joint]
  joint_names : Array[String]
  rows : Array[Equality]
} derive(FromJson, ToJson)

///|
pub struct NumericArray {
  name : String
  scalar_type : String
  shape : Array[Int32]
  components : Int32
  bytes : Bytes
}

///|
pub struct Prepared {
  priv arrays : Array[NumericArray]
  priv metadata : Json
  priv mjcf : String
}

///|
pub fn Prepared::data(self : Prepared) -> Json {
  snapshot(self.metadata)
}

///|
fn snapshot(value : Json) -> Json {
  match value {
    Object(items) => {
      let copy : Map[String, Json] = Map([])
      for key, item in items {
        copy[key] = snapshot(item)
      }
      Json(copy)
    }
    Array(items) => Json(items.map(snapshot))
    _ => value
  }
}

///|
pub fn Prepared::mjcf(self : Prepared) -> String {
  self.mjcf
}

///|
pub fn Prepared::arrays(self : Prepared) -> Array[NumericArray] {
  self.arrays.map(a => { ..a, shape: a.shape.copy(), })
}

///|
fn finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

///|
fn strict(value : Json, allowed : Array[String]) -> Unit raise {
  guard value is Object(items) && items.keys().all(k => allowed.contains(k)) else {
    fail("schema/constraint request has unknown fields or is not an object")
  }
}

///|
pub fn decode_schema(value : Json) -> SchemaRequest raise {
  strict(value, ["resolvers", "prim_type", "attributes", "keys", "defaults"])
  @json.from_json(value)
}

///|
pub fn decode_equalities(value : Json) -> EqualityRequest raise {
  strict(value, [
    "world_count", "body_world", "body_names", "joints", "joint_names", "rows",
  ])
  let request : EqualityRequest = @json.from_json(value)
  guard value is { "joints": Array(joints), "rows": Array(rows), .. } else {
    fail("constraint joints and rows must be arrays")
  }
  for joint in joints {
    strict(joint, ["world", "linear_dofs", "angular_dofs"])
  }
  for row in rows {
    strict(row, [
      "kind", "world", "body1", "body2", "joint1", "joint2", "anchor", "relpose",
      "torquescale", "polycoef", "label", "enabled", "solref", "solimp",
    ])
  }
  request
}
