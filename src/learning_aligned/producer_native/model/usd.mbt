///|
fn wire_u32(out : Array[Byte], value : Int32) -> Unit {
  for i in 0..<4 {
    out.push(((value.reinterpret_as_uint() >> (8 * i)) & 255U).to_byte())
  }
}

///|
fn wire_text(out : Array[Byte], value : String) -> Unit raise {
  guard !value.is_empty() && !value.contains("\u{0}") else {
    fail("USD variant names/selections must be nonempty and NUL-free")
  }
  let bytes = @utf8.encode(value)
  guard bytes.length() <= 1048576 else { fail("USD variant string too large") }
  wire_u32(out, bytes.length())
  for byte in bytes {
    out.push(byte)
  }
}

///|
/// Open a real OpenUSD stage through the native adapter, select existing variants
/// on the default prim in an anonymous session layer, and resolve dependencies.
/// No source USD file is saved, no USD-to-Newton model is claimed.
pub async fn validate_usd(
  usd_adapter : String,
  usd : String,
  variants : Map[String, String],
) -> Json {
  guard variants.length() <= 256 else {
    fail("at most 256 USD variants supported")
  }
  let adapter = explicit_file(usd_adapter)
  let source = explicit_file(usd)
  let adapter_sha = file_sha(adapter)
  let source_sha = file_sha(source)
  let wire : Array[Byte] = []
  wire_u32(wire, variants.length())
  let names = variants.keys().collect()
  names.sort()
  for name in names {
    wire_text(wire, name)
    wire_text(wire, variants[name])
  }
  let handle = open_usd(
    @utf8.encode(adapter),
    @utf8.encode(source),
    Bytes::from_array(wire),
  )
  defer preparation_close(handle)
  let metadata = handle.json("moonrobo.aligned-native-usd-metadata.v1")
  guard file_sha(adapter) == adapter_sha && file_sha(source) == source_sha else {
    fail("USD preparation inputs changed while stage was open")
  }
  {
    "format": "moonrobo.aligned-native-usd-receipt.v1",
    "usd_adapter": Json(adapter),
    "usd_adapter_sha256": Json(adapter_sha),
    "source_usd": Json(source),
    "source_usd_sha256": Json(source_sha),
    "metadata": metadata,
    "root_input_hash_scope": "adapter and root USD; dependency paths are reported in metadata",
    "python_used": false,
    "stage_files_modified": false,
    "physical_equivalence_verified": false,
  }
}
