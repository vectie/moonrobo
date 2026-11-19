///|
/// Versioned MoonBit checkpoint, intentionally distinct from Torch pickle/.pt.
/// Optimizer arrays, RNG state and experiment configuration belong in metadata
/// or tensors; callers must supply all state required for a resumable run.
pub(all) struct Checkpoint {
  format : String
  model_kind : String
  metadata : Json
  tensors : Map[String, Json]
} derive(Debug, ToJson, FromJson)

///|
pub fn Checkpoint::new(model_kind : String, metadata : Json) -> Checkpoint {
  {
    format: "moonrobo.moonbit-checkpoint.v1",
    model_kind,
    metadata,
    tensors: {},
  }
}

///|
pub fn Checkpoint::put(
  self : Checkpoint,
  name : String,
  shape : Array[Int32],
  values : Array[Double],
) -> Unit raise {
  ignore(encode_npy(shape, values))
  self.tensors[name] = {
    "shape": shape.to_json(),
    "values": values.to_json(),
    "dtype": "<f8",
  }
}

///|
pub fn Checkpoint::tensor(
  self : Checkpoint,
  name : String,
) -> NumericArray raise {
  guard self.tensors.get(name) is Some(value) else {
    fail("missing checkpoint tensor: " + name)
  }
  let shape = array(field(value, "shape")).map(integer)
  guard text(field(value, "dtype")) == "<f8" else {
    fail("unsupported checkpoint tensor dtype")
  }
  let mut count = 1
  for size in shape {
    guard size == 0 || count <= 2147483647 / size else {
      fail("checkpoint shape overflow")
    }
    count *= size
  }
  { shape, dtype: "<f8", values: numbers(field(value, "values"), count), }
}

///|
pub fn Checkpoint::validate(self : Checkpoint) -> Unit raise {
  guard self.format == "moonrobo.moonbit-checkpoint.v1" && self.model_kind != "" else {
    fail("unsupported MoonBit checkpoint")
  }
  for name, _ in self.tensors {
    ignore(self.tensor(name))
  }
}

///|
pub async fn save_checkpoint(path : String, checkpoint : Checkpoint) -> String {
  checkpoint.validate()
  let bytes = @utf8.encode(checkpoint.to_json().stringify())
  @fs.write_file(path, bytes, create_mode=CreateOrTruncate)
  sha256(bytes)
}

///|
pub async fn load_checkpoint(
  path : String,
  expected_kind : String,
  expected_sha256? : String,
) -> Checkpoint {
  let bytes = @fs.read_file(path).binary()
  if expected_sha256 is Some(expected) {
    guard sha256(bytes) == expected else { fail("checkpoint SHA256 differs") }
  }
  let checkpoint : Checkpoint = @json.from_json(
    @json.parse(@utf8.decode(bytes)),
  )
  checkpoint.validate()
  guard checkpoint.model_kind == expected_kind else {
    fail("checkpoint model kind differs")
  }
  checkpoint
}
