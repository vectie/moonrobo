///|
pub(all) struct IndexRows {
  binding : String
  indices : Array[Array[Int32]]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct IndexList {
  binding : String
  indices : Array[Int32]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct ComWrites {
  binding : String
  indices : Array[Array[Int32]]
  base : Array[Array[Double]]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct ContextWrites {
  shape_friction : IndexRows
  ground_friction : IndexList
  torso_com : ComWrites
} derive(Debug, ToJson, FromJson)

///|
/// All physical model writes are float32, in bounds and pairwise disjoint,
/// including ground and robot shape friction when sharing the same owner.
pub fn ContextWrites::validate(
  self : ContextWrites,
  union : NumericUnion,
  rows : Int32,
) -> Unit raise ContractError {
  guard rows > 0 &&
    self.shape_friction.indices.length() == rows &&
    self.torso_com.indices.length() == rows &&
    self.torso_com.base.length() == rows &&
    !self.ground_friction.indices.is_empty() else {
    raise Invalid("physical-context map/world cardinality is incomplete")
  }
  let occupied : Map[String, Array[Int32]] = Map([])
  let add = fn(binding : String, indices : Array[Int32]) raise ContractError {
    let region = union.region(binding)
    guard region.scalar_type == F32 else {
      raise Invalid(
        "physical context requires an actual float32 model allocation",
      )
    }
    let prior = occupied.get_or_default(binding, [])
    for index in indices {
      guard index >= 0 && index < region.bytes / 4 && !prior.contains(index) else {
        raise Invalid(
          "physical-context index is out of bounds or aliases another write",
        )
      }
      prior.push(index)
    }
    occupied[binding] = prior
  }
  for indices in self.shape_friction.indices {
    guard !indices.is_empty() else {
      raise Invalid("world has no robot friction shape")
    }
    add(self.shape_friction.binding, indices)
  }
  add(self.ground_friction.binding, self.ground_friction.indices)
  for i, indices in self.torso_com.indices {
    guard indices.length() == 3 &&
      self.torso_com.base[i].length() == 3 &&
      self.torso_com.base[i].all(fn(x) { !x.is_nan() && !x.is_inf() }) else {
      raise Invalid(
        "torso COM map must contain three finite components per world",
      )
    }
    add(self.torso_com.binding, indices)
  }
}
