///|
type NativeCompiledBlock

///|
type NativeCompiledOutputs

///|
#borrow(backend, block, inputs)
extern "c" fn compiled_block_many(
  backend : Backend,
  block : NativeCompiledBlock,
  inputs : FixedArray[NativeTensor],
) -> NativeCompiledOutputs = "mr_compiled_block_many_call"

///|
#borrow(backend, outputs)
extern "c" fn compiled_outputs_count(
  backend : Backend,
  outputs : NativeCompiledOutputs,
) -> Int32 = "mr_compiled_outputs_count_call"

///|
#borrow(backend, outputs)
extern "c" fn compiled_outputs_get(
  backend : Backend,
  outputs : NativeCompiledOutputs,
  index : Int32,
) -> NativeTensor = "mr_compiled_outputs_get_call"

///|
/// Experimental fixed-shape compiled forward/VJP pair. The package contains
/// executable native code and must be produced by the trusted, pinned exporter.
pub struct CompiledBlock {
  backend : Backend
  native : NativeCompiledBlock
}

///|
#borrow(backend)
extern "c" fn compiled_block_supported(backend : Backend) -> Bool = "mr_compiled_block_supported_call"

///|
#borrow(backend, path)
extern "c" fn compiled_block_load(
  backend : Backend,
  path : Bytes,
  device : Int32,
) -> NativeCompiledBlock = "mr_compiled_block_load_call"

///|
#borrow(backend, block, inputs)
extern "c" fn compiled_block_run(
  backend : Backend,
  block : NativeCompiledBlock,
  inputs : FixedArray[NativeTensor],
) -> NativeTensor = "mr_compiled_block_run_call"

///|
pub fn Backend::has_compiled_block(self : Backend) -> Bool {
  compiled_block_supported(self)
}

///|
/// Load a pinned AOTInductor package for one CUDA device. Shape, stride, dtype,
/// Torch version and device architecture mismatches fail; there is no fallback.
/// V1-V3 retain TF32 admission. V4 declares `ieee` or `tf32` in native.spec;
/// the active FP32 matmul policy must match before any package is loaded.
pub fn Backend::load_compiled_block(
  self : Backend,
  directory : String,
  cuda_device~ : Int32,
) -> CompiledBlock raise TensorError {
  let native = compiled_block_load(self, @utf8.encode(directory), cuda_device)
  self.check()
  { backend: self, native, }
}

///|
/// Execute using live inputs and parameters. First-order input and parameter
/// gradients compose with ordinary autograd. The enclosing training operation
/// needs its own numerical gate; an isolated MLP gate does not validate rollout.
pub fn CompiledBlock::forward(
  self : CompiledBlock,
  inputs : Array[Tensor],
) -> Tensor raise TensorError {
  let native = compiled_block_run(
    self.backend,
    self.native,
    FixedArray::makei(inputs.length(), i => inputs[i].native),
  )
  self.backend.check()
  { backend: self.backend, native, }
}

///|
/// Preserve a compiled function's separate tensor outputs and gradient edges.
/// Outputs own their storage independently of this temporary result container.
pub fn CompiledBlock::forward_many(
  self : CompiledBlock,
  inputs : Array[Tensor],
) -> Array[Tensor] raise TensorError {
  let outputs = compiled_block_many(
    self.backend,
    self.native,
    FixedArray::makei(inputs.length(), i => inputs[i].native),
  )
  self.backend.check()
  let count = compiled_outputs_count(self.backend, outputs)
  self.backend.check()
  Array::makei(count, i => {
    let native = compiled_outputs_get(self.backend, outputs, i)
    self.backend.check()
    { backend: self.backend, native, }
  })
}
