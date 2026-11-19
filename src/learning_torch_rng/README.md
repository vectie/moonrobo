# Optional ATen CPU RNG adapter

`Generator::open(adapter, seed)` loads an explicit native plugin. Ordinary
MoonBit builds do not link LibTorch. `normal(count)` makes exactly one
`at::randn({count}, generator, CPU Float)` call, then converts each sampled Float
to Double without changing its value. `indices(high, count)` uses one CPU Long
`at::randint` call. State bytes come from ATen `get_state` and are restored through
`set_state`; they include generator caches.

Keep the same LibTorch version, CPU kernels, batch counts and call order as the
original Python program. This adapter restores the original RNG implementation;
it does not make MoonBit Double arithmetic equal to PyTorch Float32 training.
The adapter ABI is version 1. `Generator::version()` reports `TORCH_VERSION`.

Deferred build example:

```sh
cmake -S src/learning_torch_rng -B target/torch-rng -DCMAKE_PREFIX_PATH=/ABSOLUTE/torch/share/cmake
cmake --build target/torch-rng
```

The library is named `libmoonrobo_aten_rng.dylib` on macOS or
`libmoonrobo_aten_rng.so` on Linux. Build against the exact LibTorch installation
used for replay. CMake preserves `TORCH_CXX_FLAGS`, including Linux's C++ ABI flag.
C++ exceptions are caught inside every fallible exported C function. The MoonBit
GC finalizer releases the generator and buffers while retaining the plugin module
for process lifetime, since LibTorch owns global pools and background threads.

Validation performed: MoonBit native type checking; `loader.c` C syntax checking;
`adapter.cpp` C++17 syntax checking against the local Torch headers. No shared
library build, sample generation, state-roundtrip test or other runtime test was
performed. Those checks remain deferred with the rest of this migration.
