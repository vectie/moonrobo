# Learning artifact bridge

This package supplies the actual I/O needed by the parallel MoonBit programs; it does not execute Python. Its `WindowBatch` implements the data-loading portion of `dynamics.py` and the logical/storage digest distinction exercised by `test_window_batch.py`.

| Feature | Implementation and contract |
| --- | --- |
| Flat batches | Exact byte SHA256, split/layout/horizon/shape checks, finite numbers, first timestamp per window |
| gzip | Native dynamically loaded system zlib, checked errors, single-member input, explicit size bound |
| Shards | Recursive loading, manifest digest/layout/horizon/count checks, concatenated field order, depth bound |
| Compatibility | Model/frame/dt/state/action/context checks; optional dataset ID identity |
| NumPy | Numeric C-order NPY decoding and float64 encoding; stored/deflated NPZ, local/central metadata checks and CRC32; deterministic float64 NPZ output |
| JSON/JSONL | Plain and `.gz` load/save, stored-byte SHA256; JSONL includes final newline for nonempty streams |
| Checkpoints | Explicit versioned MoonBit JSON, finite tensor values/shapes, optional SHA256 verification, model-kind verification |
| Comparison | Shape/field checks and `atol + rtol * abs(reference)` tolerance, nonfinite rejection, first differences with paths |
| Torch input | Restricted protocol 2/4 data-only pickle VM over checked ZIP entries; numeric storage/view reconstruction and ordinary metadata; explicit model adapters in the owning packages |

The native comparator product is `cmd/learning_compare`; it was compiled but not run against learning data. Tests were written and type checked, not executed. Native C syntax and native CLI compilation have been checked. This does not validate compression, archive, tensor or learning equivalence at runtime.

The Python `WindowBatch` casts most tensors to float32. This parallel package retains Double values; the training packages document the resulting numerical and RNG differences. Unsupported NPY dtypes/orders fail explicitly. ZIP64 end records and member metadata are supported within addressable byte-array sizes. New generic checkpoints do not claim to contain sufficient optimizer/RNG state unless the owning model wrapper saves it.

The async filesystem implementation is native-oriented; browser/Wasm target support is not established. See the repository migration document for deferred validation and package ownership.

Torch input permits only numeric storage tokens, OrderedDict and the explicit tensor/parameter rebuild signatures; no Python globals are imported or executed. Unsupported objects/opcodes, active tensor metadata, negative strides and unsupported byte order fail explicitly. Raw tensor infinities are retained for model-specific bound masks, but ordinary JSON/checkpoint output still rejects nonfinite values. Tensor views are bounded to 16M elements each and 128M total materialized elements. Legacy non-ZIP serialization is unsupported. This importer is not a general Python pickle implementation.

Serialization references: [PyTorch serialization format](https://docs.pytorch.org/docs/stable/notes/serialization.html), [official tensor rebuild implementation](https://github.com/pytorch/pytorch/blob/main/torch/_utils.py), [Python pickle opcode documentation](https://docs.python.org/3/library/pickletools.html). No existing Torch checkpoint was loaded during this session; test source was written for later validation.

The data interpreter also recognizes the primitive numeric NumPy ndarray state found in aligned MuJoCo checkpoints: `_reconstruct` (old/new NumPy core namespace), `ndarray`, primitive `dtype` version-3 state and C-order ndarray version-1 BUILD with checked raw bytes. Protocol-2 latin1 byte encoding is implemented as a data conversion, without calling `_codecs`. Float32/64, Int32/64, byte and bool arrays use the same bounds and exact-integer checks as Torch storage. Structured/object arrays, metadata, Fortran order and big-endian data remain explicit errors. Hand-authored wire fixtures are written but unexecuted. The layout follows the [NumPy ndarray pickle state](https://numpy.org/doc/stable/reference/generated/numpy.ndarray.__setstate__.html) and [dtype implementation](https://github.com/numpy/numpy/blob/main/numpy/_core/src/multiarray/descriptor.c).

`test_window_batch.py` is translated in full as the deferred async `plain gzip shards preserve every batch field and detect tampering` test in `artifacts_test.mbt`: all seven tensor fields, logical/storage hashes, concatenation, tamper rejection and dataset/dt compatibility checks are represented. It has only been type checked.
