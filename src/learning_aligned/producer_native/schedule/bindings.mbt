///|
/// Actual native metadata, tied to the validated numerical union. Addresses
/// remain UInt64 and never make a floating-point JSON round trip.
pub(all) struct NativeOperand {
  name : String
  view : @contracts.BufferView
  rows : Int32
  scalar_type : @contracts.ScalarType
  address : UInt64
  owner_address : UInt64
  owner_bytes : Int64
} derive(Debug)

///|
/// This is an explicit implementation inventory, not an assertion that a
/// library was loaded or a kernel executed. The lowering layer must construct
/// it from real native exports or compiled modules, after hashing their bytes.
pub(all) struct NativeImplementation {
  operation_key : String
  module_key : String
  entrypoint : String
  source : @contracts.BundleFile
  operands : Array[String]
} derive(Debug)

///|
pub fn validate_operands(
  union : @contracts.NumericUnion,
  operands : Array[NativeOperand],
) -> Unit raise {
  let names : Array[String] = []
  let regions = union.regions()
  for operand in operands {
    guard !operand.name.is_empty() &&
      !operand.name.contains("\u{0}") &&
      !names.contains(operand.name) else {
      raise Invalid("native operand name is invalid or duplicated")
    }
    names.push(operand.name)
    operand.view.validate(union, operand.rows)
    let candidates = regions.filter(fn(region) {
      region.name() == operand.view.binding
    })
    guard candidates.length() == 1 else {
      raise Invalid("native operand has no unique owned numerical base")
    }
    let region = candidates[0]
    guard region.scalar_type() == operand.scalar_type &&
      region.address() == operand.owner_address &&
      region.bytes().to_int64() == operand.owner_bytes else {
      raise Invalid(
        "native operand dtype/owner address/byte capacity differs from observed allocation",
      )
    }
    let offset = operand.view.offset_elements.to_uint64() *
      region.scalar_bytes().to_uint64()
    guard operand.address == region.address() + offset else {
      raise Invalid(
        "native operand address differs from its typed component layout",
      )
    }
  }
}

///|
/// Enumerates all required operation keys, including each actual callback.
/// Source planning is useful before every implementation is available; native
/// lowering must call this gate and fail on the first missing operation.
pub fn Schedule::required_operations(self : Schedule) -> Array[String] {
  let result : Array[String] = []
  for
    role in [
      @contracts.Step,
      @contracts.Reset,
      @contracts.Context,
      @contracts.Refresh,
    ] {
    for node in self.operations(role) {
      let key = node.operation.key()
      if !result.contains(key) {
        result.push(key)
      }
    }
  }
  result
}

///|
/// Completeness and byte-identity checks only. The caller supplies observed
/// source hashes; this package does not read files, discover shared libraries,
/// bind arbitrary symbols or claim that these implementations are equivalent.
pub fn Schedule::validate_native_coverage(
  self : Schedule,
  union : @contracts.NumericUnion,
  operands : Array[NativeOperand],
  implementations : Array[NativeImplementation],
) -> Unit raise {
  validate_operands(union, operands)
  let needed = self.required_operations()
  let seen : Array[String] = []
  let operand_names = operands.map(fn(operand) { operand.name })
  for implementation in implementations {
    guard needed.contains(implementation.operation_key) &&
      !seen.contains(implementation.operation_key) &&
      !implementation.module_key.is_empty() &&
      !implementation.module_key.contains("\u{0}") &&
      !implementation.entrypoint.is_empty() &&
      !implementation.entrypoint.contains("\u{0}") else {
      raise Invalid(
        "native implementation identity is absent/duplicated/unused",
      )
    }
    let file = implementation.source
    guard @contracts.relative_path(file.path) &&
      @contracts.sha256_hex(file.expected_sha256) &&
      file.expected_sha256 == file.observed_sha256 else {
      raise Invalid("native implementation source path/hash was not verified")
    }
    let used_operands : Array[String] = []
    for name in implementation.operands {
      guard operand_names.contains(name) && !used_operands.contains(name) else {
        raise Invalid(
          "native operation references an absent/duplicated typed buffer operand",
        )
      }
      used_operands.push(name)
    }
    seen.push(implementation.operation_key)
  }
  for key in needed {
    guard seen.contains(key) else { raise MissingBackend(key) }
  }
}
