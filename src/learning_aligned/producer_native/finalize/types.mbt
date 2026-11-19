///|
pub(all) struct CommandRequest {
  builder_request : @builder.PrepareRequest
  scalar_type : String
  target_layout : String
} derive(FromJson)

///|
/// Actual packed bytes for one contiguous Warp-style array. `components`
/// denotes a scalar/vector/matrix/transform element, distinct from array rank.
pub struct HostArray {
  scalar_type : String
  shape : Array[Int32]
  components : Int32
  bytes : Bytes
}

///|
/// A contiguous byte view into one owned physical array. No nested aliasing or
/// additional allocation; the base controls dtype and lifetime.
pub struct ArrayAlias {
  base : String
  offset_bytes : Int32
  shape : Array[Int32]
  components : Int32
}

///|
/// Owns independently packed model/state/control data for a rigid-tree subset.
/// It is not a Newton Model and has no implicit device/context initialization.
pub struct HostLayout {
  arrays : Map[String, HostArray]
  aliases : Map[String, ArrayAlias]
  storage_scope : Json
  body_count : Int32
  joint_count : Int32
  coord_count : Int32
  dof_count : Int32
  world_count : Int32
  scalar_type : String
  target_layout : String
  mass_properties_complete : Bool
  unresolved_semantics : Array[String]
}
