///|
/// Saved native OpenUSD receipt plus explicit per-world rigid placements.
pub(all) struct BuilderRequest {
  usd_receipt : String
  usd_receipt_sha256 : String
  num_envs : Int32
  self_collisions : Bool
  placements : Array[@builder.Placement]
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct ConstantsRequest {
  request : @constants.CommandRequest
  output : String
} derive(FromJson, ToJson)

///|
pub(all) struct MassLayoutRequest {
  nv : Int32
  row_adr : Array[Int32]
  row_nnz : Array[Int32]
  col_ind : Array[Int32]
  output : String
} derive(FromJson, ToJson)

///|
/// Every receipt hashes the actual emitted bytes. These are CPU data artifacts,
/// not a finalized Newton model, CUDA image, APIC bundle or equivalence proof.
async fn write_fragment(
  output : String,
  format : String,
  input : Json,
  result : Json,
) -> Json {
  guard !@fs.exists(output) else {
    fail("native preparation requires a fresh output directory")
  }
  let bytes = @utf8.encode(result.stringify(indent=2) + "\n")
  @fs.mkdir(output, recursive=true)
  @fs.write_file(
    output + "/input.json",
    input.stringify(indent=2) + "\n",
    create_mode=CreateNew,
  )
  @fs.write_file(output + "/result.json", bytes, create_mode=CreateNew)
  let receipt : Json = {
    "format": format.to_json(),
    "result_path": "result.json",
    "result_sha256": @artifacts.sha256(bytes).to_json(),
    "numeric_backend": "CPU/Double",
    "python_interpreter_initialized": false,
    "newton_device_model_constructed": false,
    "full_physics_closure": false,
    "runtime_equivalence_verified": false,
  }
  @fs.write_file(
    output + "/receipt.json",
    receipt.stringify(indent=2) + "\n",
    create_mode=CreateNew,
  )
  receipt
}

///|
pub async fn prepare_builder(request : BuilderRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("native builder preparation requires fresh output")
  }
  let source = @fs.read_file(request.usd_receipt).binary()
  guard @artifacts.sha256(source) == request.usd_receipt_sha256 else {
    fail("native USD receipt identity differs")
  }
  let arrays = @builder.prepare_from_receipt({
    usd_receipt: @json.parse(@utf8.decode(source)),
    num_envs: request.num_envs,
    self_collisions: request.self_collisions,
    placements: request.placements,
  })
  write_fragment(
    request.output,
    "moonrobo-newton-builder-arrays.v1",
    request.to_json(),
    arrays.to_json(),
  )
}

///|
pub async fn prepare_constants(request : ConstantsRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("constant preparation requires fresh output")
  }
  let result = @constants.prepare_constants(request.request)
  write_fragment(
    request.output,
    "moonrobo-physical-constant-fragment.v1",
    request.request.to_json(),
    result,
  )
}

///|
pub async fn prepare_mass_layout(request : MassLayoutRequest) -> Json {
  guard !@fs.exists(request.output) else {
    fail("mass-layout preparation requires fresh output")
  }
  let layout = @physics_kernels.mass_gather_layout(
    request.nv,
    request.row_adr,
    request.row_nnz,
    request.col_ind,
  )
  write_fragment(
    request.output,
    "moonrobo-sparse-mass-gather-layout.v1",
    request.to_json(),
    layout.to_json(),
  )
}
