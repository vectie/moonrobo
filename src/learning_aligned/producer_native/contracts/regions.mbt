///|
/// Pure metadata validation. No interpreter, SDK, GPU, filesystem or pointer
/// dereference is involved. Native observers supply actual allocation facts.
pub suberror ContractError {
  Invalid(String)
} derive(Debug)

///|
/// Width alone does not establish pointer freedom. U8 and U64 deliberately
/// remain distinct from approved persistent numerical storage.
pub(all) enum ScalarType {
  F32
  F64
  I32
  I64
  Bool8
  U8
  U64
  Opaque(String)
} derive(Debug, Eq)

///|
pub fn ScalarType::name(self : ScalarType) -> String {
  match self {
    F32 => "float32"
    F64 => "float64"
    I32 => "int32"
    I64 => "int64"
    Bool8 => "bool"
    U8 => "uint8"
    U64 => "uint64"
    Opaque(name) => name
  }
}

///|
pub fn scalar_type(name : String) -> ScalarType {
  match name {
    "float32" => F32
    "float64" => F64
    "int32" => I32
    "int64" => I64
    "bool" => Bool8
    "uint8" => U8
    "uint64" => U64
    _ => Opaque(name)
  }
}

///|
fn ScalarType::bytes(self : ScalarType) -> Int32 raise ContractError {
  match self {
    F32 | I32 => 4
    F64 | I64 | U64 => 8
    Bool8 | U8 => 1
    Opaque(_) => raise Invalid("opaque allocation has no approved scalar width")
  }
}

///|
/// Raw unsigned addresses never pass through JSON floating point numbers.
/// owner_id names the actual SDK-owned base, not a child/strided view object.
/// capture_origin is the normalized owning graph role (step/reset/context/
/// refresh), supplied only after the observer compares the actual capture
/// identity with the SDK allocation's capture-origin metadata.
pub(all) struct Allocation {
  owner_id : String
  address : UInt64
  bytes : Int64
  scalar_type : ScalarType
  capture_origin : String?
} derive(Debug, Eq)

///|
/// A validated primitive persistent base. Construction is package-private.
pub struct NumericRegion {
  name : String
  owner_id : String
  address : UInt64
  bytes : Int32
  scalar_type : ScalarType
  scalar_bytes : Int32
} derive(Debug)

///|
pub fn NumericRegion::name(self : NumericRegion) -> String {
  self.name
}

///|
pub fn NumericRegion::owner_id(self : NumericRegion) -> String {
  self.owner_id
}

///|
pub fn NumericRegion::address(self : NumericRegion) -> UInt64 {
  self.address
}

///|
pub fn NumericRegion::bytes(self : NumericRegion) -> Int32 {
  self.bytes
}

///|
pub fn NumericRegion::scalar_type(self : NumericRegion) -> ScalarType {
  self.scalar_type
}

///|
pub fn NumericRegion::scalar_bytes(self : NumericRegion) -> Int32 {
  self.scalar_bytes
}

///|
fn allocation_end(allocation : Allocation) -> UInt64 raise ContractError {
  guard !allocation.owner_id.is_empty() &&
    !allocation.owner_id.contains("\u{0}") &&
    allocation.address != 0UL &&
    allocation.bytes > 0L &&
    allocation.bytes <= 2147483647L else {
    raise Invalid(
      "allocation needs a real base owner/address and exact positive Int32 byte capacity",
    )
  }
  let bytes = allocation.bytes.to_uint64()
  guard allocation.address <= 0xFFFFFFFFFFFFFFFFUL - bytes else {
    raise Invalid("allocation address range overflows uintptr64")
  }
  allocation.address + bytes
}

///|
fn numeric_region(
  allocation : Allocation,
  name : String,
) -> NumericRegion raise ContractError {
  ignore(allocation_end(allocation))
  guard allocation.capture_origin is None else {
    raise Invalid(
      "capture-scoped allocation escaped into persistent numerical state",
    )
  }
  guard allocation.scalar_type is (F32 | F64 | I32 | I64 | Bool8) else {
    raise Invalid(
      "unclassified uint8/uint64/opaque allocation cannot enter numerical union",
    )
  }
  let scalar_bytes = allocation.scalar_type.bytes()
  guard allocation.bytes % scalar_bytes.to_int64() == 0L &&
    allocation.address % scalar_bytes.to_uint64() == 0UL else {
    raise Invalid("numerical allocation capacity/address is not scalar aligned")
  }
  {
    name,
    owner_id: allocation.owner_id,
    address: allocation.address,
    bytes: allocation.bytes.to_int(),
    scalar_type: allocation.scalar_type,
    scalar_bytes,
  }
}

///|
fn disjoint(a : Allocation, b : Allocation) -> Bool raise ContractError {
  let ae = allocation_end(a)
  let be = allocation_end(b)
  ae <= b.address || be <= a.address
}

///|
fn add_numeric(
  regions : Array[NumericRegion],
  allocation : Allocation,
) -> Unit raise ContractError {
  let candidate = numeric_region(
    allocation,
    "shared_" + regions.length().to_string(),
  )
  for region in regions {
    if region.address == candidate.address {
      guard region.bytes == candidate.bytes &&
        region.scalar_type == candidate.scalar_type else {
        raise Invalid(
          "aliased numerical bases disagree on capacity or scalar type",
        )
      }
      return
    }
    guard region.owner_id != candidate.owner_id else {
      raise Invalid("one base owner identity names multiple addresses")
    }
    let prior : Allocation = {
      owner_id: region.owner_id,
      address: region.address,
      bytes: region.bytes.to_int64(),
      scalar_type: region.scalar_type,
      capture_origin: None,
    }
    guard disjoint(prior, allocation) else {
      raise Invalid(
        "partially overlapping numerical bases cannot be synchronized independently",
      )
    }
  }
  regions.push(candidate)
}

///|
/// Opaque validated union. Arrays returned by accessors are copies.
pub struct NumericUnion {
  regions : Array[NumericRegion]
}

///|
pub fn NumericUnion::regions(self : NumericUnion) -> Array[NumericRegion] {
  self.regions.copy()
}

///|
/// Manifest fragments omit raw pointers and any claim of capture success.
pub fn NumericUnion::to_json(self : NumericUnion) -> Json {
  self.regions
  .map(fn(r) {
    {
      "name": r.name.to_json(),
      "bytes": r.bytes.to_json(),
      "scalar_type": r.scalar_type.name().to_json(),
    }
  })
  .to_json()
}
