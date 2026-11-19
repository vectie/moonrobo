///|
type NativeModel

///|
#borrow(library, scene)
extern "c" fn open_model(library : Bytes, scene : Bytes) -> NativeModel = "moonrobo_replay_model_open"

///|
#borrow(model)
extern "c" fn model_error(model : NativeModel) -> Bytes = "moonrobo_replay_model_error"

///|
#borrow(model)
extern "c" fn model_count(
  model : NativeModel,
  kind : Int32,
  id : Int32,
) -> Int32 = "moonrobo_replay_model_count"

///|
#borrow(model)
extern "c" fn model_value(
  model : NativeModel,
  kind : Int32,
  id : Int32,
  component : Int32,
) -> Double = "moonrobo_replay_model_value"

///|
fn model_vector(
  model : NativeModel,
  kind : Int32,
  id : Int32,
  width : Int32,
) -> Array[Double] {
  Array::makei(width, i => model_value(model, kind, id, i))
}

///|
fn mesh_obj(model : NativeModel, mesh : Int32) -> Bytes raise {
  let vertices = model_count(model, 2, mesh)
  let faces = model_count(model, 3, mesh)
  guard vertices > 0 && vertices <= 1000000 && faces > 0 && faces <= 2000000 else {
    fail("compiled replay mesh exceeds vertex/triangle budget or is empty")
  }
  let text = StringBuilder()
  text.write_string("# Compiled MuJoCo mesh; geom local frame; meters\n")
  for i in 0..<vertices {
    let x = model_value(model, 10, mesh, i * 3)
    let y = model_value(model, 10, mesh, i * 3 + 1)
    let z = model_value(model, 10, mesh, i * 3 + 2)
    guard !x.is_nan() &&
      !x.is_inf() &&
      !y.is_nan() &&
      !y.is_inf() &&
      !z.is_nan() &&
      !z.is_inf() else {
      fail("nonfinite compiled mesh vertex")
    }
    text.write_string("v \{x} \{y} \{z}\n")
  }
  for i in 0..<faces {
    let indices = Array::makei(3, j => {
      model_value(model, 11, mesh, i * 3 + j).to_int()
    })
    guard indices.all(index => index >= 0 && index < vertices) else {
      fail("compiled mesh triangle references an unknown vertex")
    }
    text.write_string(
      "f \{indices[0] + 1} \{indices[1] + 1} \{indices[2] + 1}\n",
    )
  }
  @utf8.encode(text.to_string())
}

///|
/// Reads the same compiled MJCF as the pose runtime. Compiled mesh vertices
/// already include MuJoCo scaling/centering; geom_pos/quat carry the corresponding
/// compensation. Applying source mesh transforms again would misplace meshes.
pub async fn export_model(
  runtime : @physics.Runtime,
  library : String,
  scene : String,
  asset_directory : String,
) -> @replay.Model {
  let model = open_model(@utf8.encode(library), @utf8.encode(scene))
  let error = @utf8.decode_lossy(model_error(model))
  guard error == "" else { fail(error) }
  guard model_count(model, 1, 0) == runtime.body_count() else {
    fail("visual model and pose model body counts differ")
  }
  let bodies : Array[@replay.Body] = []
  for i in 0..<runtime.body_count() {
    bodies.push({
      id: i.to_string(),
      name: runtime.body_name(i),
      parent_id: if i == 0 {
        None
      } else {
        Some(runtime.body_parent(i).to_string())
      },
    })
  }
  let meshes : Map[Int32, Json] = Map([])
  let visuals : Array[@replay.Visual] = []
  @fs.mkdir(asset_directory, recursive=true)
  for i in 0..<model_count(model, 0, 0) {
    let rgba = model_vector(model, 6, i, 4)
    // MuJoCo's default visible groups are 0,1,2. Group 3+ collision helper
    // geometry remains absent rather than obscuring the visible robot meshes.
    if model_value(model, 7, i, 0) > 2 || rgba[3] == 0 {
      continue
    }
    let size = model_vector(model, 3, i, 3)
    let kind = model_value(model, 0, i, 0).to_int()
    let geometry : Json = match kind {
      0 => { "kind": "plane", "size": [2.0 * size[0], 2.0 * size[1]] }
      2 => { "kind": "sphere", "radius": size[0] }
      3 => { "kind": "capsule", "radius": size[0], "length": 2.0 * size[1] }
      4 => { "kind": "ellipsoid", "radii": size }
      5 => { "kind": "cylinder", "radius": size[0], "length": 2.0 * size[1] }
      6 => { "kind": "box", "size": size.map(x => 2.0 * x) }
      7 => {
        let id = model_value(model, 2, i, 0).to_int()
        if !meshes.contains(id) {
          let bytes = mesh_obj(model, id)
          let sha = @artifacts.sha256(bytes)
          let name = sha + ".obj"
          let path = asset_directory + "/" + name
          if @fs.exists(path) {
            guard @artifacts.sha256(@fs.read_file(path).binary()) == sha else {
              fail("existing content-addressed replay asset has changed")
            }
          } else {
            @fs.write_file(path, bytes, create_mode=CreateOrTruncate)
          }
          meshes[id] = {
            "kind": "mesh",
            "asset": name,
            "sha256": sha,
            "scale": [1, 1, 1],
          }
        }
        meshes[id]
      }
      _ =>
        fail(
          "visible MuJoCo geometry is not supported by replay exporter: \{kind}",
        )
    }
    visuals.push({
      id: "geom-\{i}",
      body_id: model_value(model, 1, i, 0).to_int().to_string(),
      geometry,
      local_position: model_vector(model, 4, i, 3),
      local_quaternion_wxyz: model_vector(model, 5, i, 4),
      rgba,
    })
  }
  let descriptor : Json = {
    "coordinate_system": "right-handed-z-up",
    "bodies": bodies,
    "visuals": visuals,
  }
  let sha = @artifacts.sha256(@utf8.encode(descriptor.stringify()))
  let result : @replay.Model = {
    id: "mujoco-" + sha[:16].to_owned(),
    sha256: sha,
    coordinate_system: "right-handed-z-up",
    bodies,
    visuals,
  }
  result.validate()
  result
}

///|
/// Capture a full world-space frame after the caller has advanced or restored
/// its runtime. This function itself does not step, reset, or alter MuJoCo.
pub fn capture_frame(
  runtime : @physics.Runtime,
  time_s : Double,
) -> @replay.PoseFrame raise {
  let bodies : Array[@replay.BodyPose] = []
  for i in 0..<runtime.body_count() {
    bodies.push({
      body_id: i.to_string(),
      position: runtime.body_world_pos(i),
      quaternion_wxyz: runtime.body_world_quat(i),
    })
  }
  { time_s, bodies, }
}
