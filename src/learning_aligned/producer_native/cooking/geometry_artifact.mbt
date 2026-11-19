///|
pub(all) struct GeometryRequest {
  operation : String
  parameters : Json
} derive(FromJson, ToJson)

///|
struct MeshMassInput {
  mesh : MeshRequest
  density : Double
  is_solid : Bool
  thickness : Array[Double]
} derive(FromJson)

///|
struct PrimitiveInput {
  kind : String
  scale : Array[Double]
  density : Double
  is_solid : Bool
  thickness : Double
} derive(FromJson)

///|
struct CorrectionInput {
  mass : Double
  inertia : Array[Double]
  balance : Bool
  bound_mass : Double?
  bound_inertia : Double?
} derive(FromJson)

///|
struct ScaleInput {
  mesh : MeshRequest
  scale : Array[Double]
  preserve_winding : Bool?
} derive(FromJson)

///|
struct TopologyInput {
  mesh : MeshRequest
  lower_angle : Double
} derive(FromJson)

///|
struct HullInput {
  request : HullRequest
  adapter : String
  qhull_library : String
} derive(FromJson)

///|
struct SdfInput {
  mesh : MeshRequest
  options : SdfOptions
  adapter : String
  warp_library : String
  cache_directory : String?
} derive(FromJson)

///|
struct PrimitiveSdfInput {
  kind : String
  scale : Array[Double]
  options : SdfOptions
  cache_directory : String?
} derive(FromJson)

///|
struct EdgeInput {
  mesh : MeshRequest
  options : CollisionEdgeOptions
} derive(FromJson)

///|
struct LegacyInput {
  mesh : MeshRequest
  options : LegacySdfOptions
  adapter : String
  warp_library : String
  texture_options : SdfOptions?
} derive(FromJson)

///|
struct PrimitiveLegacyInput {
  kind : String
  scale : Array[Double]
  options : LegacySdfOptions
} derive(FromJson)

///|
struct SampleInput {
  cache_directory : String
  key : String
  positions : Array[Double]
  shape_margin : Double
  gradient : Bool
} derive(FromJson)

///|
struct IsoInput {
  cache_directory : String
  key : String
  isovalue : Double
  max_triangles : Int32
} derive(FromJson)

///|
struct MassScaleInput {
  value : MassProperties
  scale : Array[Double]
  density : Double
} derive(FromJson)

///|
struct MassTransformInput {
  value : MassProperties
  rotation : Array[Double]
  translation : Array[Double]
} derive(FromJson)

///|
pub fn decode_geometry_request(value : Json) -> GeometryRequest raise {
  strict_parameters(value, ["operation", "parameters"])
  @json.from_json(value)
}

///|
fn strict_nested(request : GeometryRequest) -> Unit raise {
  if request.parameters is Object(fields) {
    if fields.get("mesh") is Some(value) {
      strict_parameters(value, [
        "vertices", "indices", "velocities", "groups", "bvh_constructor", "bvh_leaf_size",
        "support_winding_number",
      ])
    }
    let sdf_keys = [
      "margin", "narrow_band", "max_resolution", "target_voxel_size", "texture_format",
      "paired_samples", "sign_method", "linearization_error",
    ]
    if fields.get("options") is Some(value) {
      if request.operation == "collision-edges" {
        strict_parameters(value, [
          "lower_angle", "upper_angle", "box_absorption", "concave_filter", "sign_method",
          "half_normal", "half_normal_relative", "half_lateral", "half_lateral_relative",
        ])
      } else if ["legacy-sdf", "legacy-texture", "primitive-legacy-sdf"].contains(
          request.operation,
        ) {
        strict_parameters(value, [
          "margin", "shape_margin", "narrow_band", "max_resolution", "target_voxel_size",
        ])
      } else {
        strict_parameters(value, sdf_keys)
      }
    }
    if fields.get("texture_options") is Some(value) && value != Json::null() {
      strict_parameters(value, sdf_keys)
    }
    if request.operation == "convex-hull" &&
      fields.get("request") is Some(value) {
      strict_parameters(value, ["vertices", "max_vertices", "rank_epsilon"])
    }
    if fields.get("value") is Some(value) {
      strict_parameters(value, ["mass", "com", "inertia", "volume"])
    }
  }
}

///|
fn strict_parameters(value : Json, keys : Array[String]) -> Unit raise {
  guard value is Object(items) && items.keys().all(k => keys.contains(k)) else {
    fail("geometry parameters have unknown fields or are not an object")
  }
}

///|
/// CPU/native-host geometry command. Device upload is only a separate typed
/// call with an explicit retained Context; this entry never creates CUDA.
pub async fn geometry_artifact(
  request : GeometryRequest,
  output : String,
) -> Json {
  guard !output.is_empty() && !@fs.exists(output) else {
    fail("fresh nonexistent geometry output directory required")
  }
  let p = request.parameters
  strict_nested(request)
  let files : Array[(String, Bytes)] = []
  let mut native = false
  fn mesh_files(mesh : PreparedMesh) -> Json {
    files.push(("points.bin", mesh.points))
    files.push(("velocities.bin", mesh.velocities))
    files.push(("indices.bin", mesh.indices))
    files.push(("groups.bin", mesh.groups))
    mesh.metadata()
  }
  fn sdf_files(sdf : SparseSdf) -> Json {
    files.push(("coarse.bin", sdf.coarse))
    files.push(("subgrid.bin", sdf.subgrid))
    files.push(("slots.bin", sdf.slots))
    sdf.metadata()
  }
  fn legacy_files(sdf : LegacySdf) -> Json {
    files.push(("sparse-tiles.bin", sdf.sparse.tiles))
    files.push(("sparse-values.bin", sdf.sparse.values))
    files.push(("coarse-tiles.bin", sdf.coarse.tiles))
    files.push(("coarse-values.bin", sdf.coarse.values))
    sdf.metadata()
  }
  let result : Json = match request.operation {
    "mesh-mass" => {
      strict_parameters(p, ["mesh", "density", "is_solid", "thickness"])
      let r : MeshMassInput = @json.from_json(p)
      mesh_mass(prepare_mesh(r.mesh), r.density, r.is_solid, r.thickness).to_json()
    }
    "primitive-mass" => {
      strict_parameters(p, ["kind", "scale", "density", "is_solid", "thickness"])
      let r : PrimitiveInput = @json.from_json(p)
      primitive_mass(r.kind, r.scale, r.density, r.is_solid, r.thickness).to_json()
    }
    "correct-inertia" => {
      strict_parameters(p, [
        "mass", "inertia", "balance", "bound_mass", "bound_inertia",
      ])
      let r : CorrectionInput = @json.from_json(p)
      correct_inertia(
        r.mass,
        r.inertia,
        r.balance,
        r.bound_mass,
        r.bound_inertia,
      ).to_json()
    }
    "scale" => {
      strict_parameters(p, ["mesh", "scale", "preserve_winding"])
      let r : ScaleInput = @json.from_json(p)
      mesh_files(
        bake_scale(
          prepare_mesh(r.mesh),
          r.scale,
          preserve_winding=r.preserve_winding.unwrap_or(false),
        ),
      )
    }
    "deduplicate" => {
      strict_parameters(p, ["mesh"])
      guard p is { "mesh": mesh, .. } else { fail("mesh required") }
      mesh_files(deduplicate(prepare_mesh(@json.from_json(mesh))))
    }
    "scale-mass" => {
      strict_parameters(p, ["value", "scale", "density"])
      let r : MassScaleInput = @json.from_json(p)
      scale_mass(r.value, r.scale, r.density).to_json()
    }
    "transform-mass" => {
      strict_parameters(p, ["value", "rotation", "translation"])
      let r : MassTransformInput = @json.from_json(p)
      transform_mass(r.value, r.rotation, r.translation).to_json()
    }
    "collision-edges" => {
      strict_parameters(p, ["mesh", "options"])
      let r : EdgeInput = @json.from_json(p)
      let edges = collision_edges(prepare_mesh(r.mesh), r.options)
      if edges is Some(values) {
        files.push(("collision-edges.bin", ints(values)))
      }
      {
        "edges": edges.to_json(),
        "lazy_full_edges_fallback": Json(edges is None),
      }
    }
    "heightfield" => {
      strict_parameters(p, [
        "nx", "ny", "heights", "extent_x", "extent_y", "center_x", "center_y", "ground_z",
      ])
      mesh_files(heightfield_mesh(@json.from_json(p)))
    }
    "topology" => {
      strict_parameters(p, ["mesh", "lower_angle"])
      let r : TopologyInput = @json.from_json(p)
      mesh_topology(prepare_mesh(r.mesh), r.lower_angle).to_json()
    }
    "convex-support" => {
      strict_parameters(p, ["mesh"])
      guard p is { "mesh": mesh, .. } else {
        fail("convex-support requires mesh")
      }
      convex_support(prepare_mesh(@json.from_json(mesh))).to_json()
    }
    "convex-hull" => {
      strict_parameters(p, ["request", "adapter", "qhull_library"])
      let r : HullInput = @json.from_json(p)
      let hull = convex_hull(r.request, r.adapter, r.qhull_library)
      if hull.rank == 3 {
        native = true
      }
      files.push(("points.bin", floats(hull.vertices)))
      files.push(("indices.bin", ints(hull.indices)))
      {
        "rank": Json(hull.rank),
        "vertex_count": Json(hull.vertices.length() / 3),
        "triangle_count": Json(hull.indices.length() / 3),
        "receipt": hull.receipt,
        "degenerate_zero_volume": Json(hull.rank < 3),
      }
    }
    "sparse-sdf" => {
      strict_parameters(p, [
        "mesh", "options", "adapter", "warp_library", "cache_directory",
      ])
      let r : SdfInput = @json.from_json(p)
      let prepared = prepare_mesh(r.mesh)
      let topology = mesh_topology(prepared, 0)
      let winding = r.options.sign_method == "winding" ||
        (r.options.sign_method == "auto" && !topology.watertight)
      let resolved = {
        ..prepared,
        support_winding_number: winding || prepared.support_winding_number,
      }
      let adapter = explicit_file(r.adapter)
      let library = explicit_file(r.warp_library)
      let a = @artifacts.sha256(@fs.read_file(adapter).binary())
      let b = @artifacts.sha256(@fs.read_file(library).binary())
      let key = mesh_sdf_cache_key(resolved, r.options, adapter, library)
      let loaded = match r.cache_directory {
        Some(directory) => load_sdf_cache(directory, key)
        None => None
      }
      let sdf = if loaded is Some(value) {
        value
      } else {
        let mesh = open_host_mesh(adapter, library, resolved)
        defer mesh.close()
        native = true
        mesh.build_sparse_sdf(r.options)
      }
      guard a == @artifacts.sha256(@fs.read_file(adapter).binary()) &&
        b == @artifacts.sha256(@fs.read_file(library).binary()) else {
        fail("SDF native inputs changed during cook")
      }
      if loaded is None && r.cache_directory is Some(directory) {
        ignore(store_sdf_cache(directory, key, sdf))
      }
      {
        "sdf": sdf_files(sdf),
        "adapter_sha256": Json(a),
        "warp_library_sha256": Json(b),
        "native_host_queries": Json(loaded is None),
        "cache_hit": Json(loaded is Some(_)),
        "cache_key": Json(key),
      }
    }
    "primitive-sdf" => {
      strict_parameters(p, ["kind", "scale", "options", "cache_directory"])
      let r : PrimitiveSdfInput = @json.from_json(p)
      let key = primitive_sdf_cache_key(r.kind, r.scale, r.options)
      let loaded = match r.cache_directory {
        Some(directory) => load_sdf_cache(directory, key)
        None => None
      }
      let sdf = loaded.unwrap_or_else(() => {
        primitive_sparse_sdf(r.kind, r.scale, r.options)
      })
      if loaded is None && r.cache_directory is Some(directory) {
        ignore(store_sdf_cache(directory, key, sdf))
      }
      {
        "sdf": sdf_files(sdf),
        "cache_key": Json(key),
        "cache_hit": Json(loaded is Some(_)),
      }
    }
    "legacy-sdf" | "legacy-texture" => {
      strict_parameters(p, [
        "mesh", "options", "adapter", "warp_library", "texture_options",
      ])
      let r : LegacyInput = @json.from_json(p)
      let prepared = { ..prepare_mesh(r.mesh), support_winding_number: true, }
      let adapter = explicit_file(r.adapter)
      let library = explicit_file(r.warp_library)
      let a = @artifacts.sha256(@fs.read_file(adapter).binary())
      let b = @artifacts.sha256(@fs.read_file(library).binary())
      let mesh = open_host_mesh(adapter, library, prepared)
      defer mesh.close()
      let legacy = mesh.build_legacy_sdf(r.options)
      let data = legacy_files(legacy)
      let result : Json = if request.operation == "legacy-texture" {
        guard r.texture_options is Some(options) else {
          fail("legacy-texture requires explicit texture_options")
        }
        {
          "volumes": data,
          "texture": sdf_files(legacy.to_texture(adapter, library, options)),
        }
      } else {
        guard r.texture_options is None else {
          fail("legacy-sdf does not consume texture_options")
        }
        data
      }
      guard a == @artifacts.sha256(@fs.read_file(adapter).binary()) &&
        b == @artifacts.sha256(@fs.read_file(library).binary()) else {
        fail("legacy cooking libraries changed")
      }
      native = true
      {
        "result": result,
        "adapter_sha256": Json(a),
        "warp_library_sha256": Json(b),
      }
    }
    "primitive-legacy-sdf" => {
      strict_parameters(p, ["kind", "scale", "options"])
      let r : PrimitiveLegacyInput = @json.from_json(p)
      legacy_files(primitive_legacy_sdf(r.kind, r.scale, r.options))
    }
    "sample-sdf" => {
      strict_parameters(p, [
        "cache_directory", "key", "positions", "shape_margin", "gradient",
      ])
      let r : SampleInput = @json.from_json(p)
      guard r.positions.length() % 3 == 0 && r.positions.length() <= 12000000 else {
        fail("bounded xyz positions required")
      }
      guard load_sdf_cache(r.cache_directory, r.key) is Some(sdf) else {
        fail("SDF cache miss")
      }
      let values : Array[Json] = []
      for i in 0..<(r.positions.length() / 3) {
        let position = [
          r.positions[i * 3],
          r.positions[i * 3 + 1],
          r.positions[i * 3 + 2],
        ]
        values.push(
          if r.gradient {
            sdf.sample_gradient(position, shape_margin=r.shape_margin).to_json()
          } else {
            Json(sdf.sample(position, shape_margin=r.shape_margin))
          },
        )
      }
      Json(values)
    }
    "isomesh" => {
      strict_parameters(p, [
        "cache_directory", "key", "isovalue", "max_triangles",
      ])
      let r : IsoInput = @json.from_json(p)
      guard load_sdf_cache(r.cache_directory, r.key) is Some(sdf) else {
        fail("SDF cache miss")
      }
      if sdf.isomesh(r.isovalue, max_triangles=r.max_triangles) is Some(mesh) {
        files.push(("points.bin", floats(mesh.vertices)))
        files.push(("indices.bin", ints(mesh.indices)))
        {
          "vertex_count": Json(mesh.vertices.length() / 3),
          "triangle_count": Json(mesh.indices.length() / 3),
          "empty": false,
        }
      } else {
        { "empty": true }
      }
    }
    _ => fail("unsupported geometry operation")
  }
  let input = @utf8.encode(request.to_json().stringify(indent=2))
  let bytes = @utf8.encode(result.stringify(indent=2))
  let identities = files.map(file => {
    "path": Json(file.0),
    "byte_length": Json(file.1.length()),
    "sha256": Json(@artifacts.sha256(file.1)),
  })
  let receipt : Json = {
    "format": "moonrobo.geometry-cooking-artifact.v1",
    "operation": Json(request.operation),
    "request_path": "request.json",
    "request_sha256": Json(@artifacts.sha256(input)),
    "result_path": "result.json",
    "result_sha256": Json(@artifacts.sha256(bytes)),
    "files": Json(identities),
    "native_host_execution_performed": Json(native),
    "cuda_context_created": false,
    "python_used": false,
    "full_newton_cooking_complete": false,
    "numeric_equivalence_verified": false,
  }
  @fs.mkdir(output, recursive=true)
  @fs.write_file(output + "/request.json", input, create_mode=CreateNew)
  @fs.write_file(output + "/result.json", bytes, create_mode=CreateNew)
  for (name, data) in files {
    @fs.write_file(output + "/" + name, data, create_mode=CreateNew)
  }
  @fs.write_file(
    output + "/manifest.json",
    receipt.stringify(indent=2),
    create_mode=CreateNew,
  )
  receipt
}
