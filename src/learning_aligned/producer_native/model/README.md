# Offline native model preparation

This package uses MoonBit → C ABI → native libraries. It has no CPython or
Python-module-discovery dependency. Adapter paths and the MuJoCo library path
are explicit; libraries are loaded only when the public functions are actually
called. A `moon check` does not load them or compile any robot model.

`prepare_model(adapter, mujoco_library, source_mjcf)` returns
`CompiledModel { descriptor, mjb, receipt }`. The adapter calls the official
`mj_loadXML`, `mj_sizeModel` and `mj_saveModel` interfaces. Runtime and header
MuJoCo versions must match exactly. The descriptor includes model dimensions,
options, body inertia, joints, actuator parameters, contacts, meshes, exclusions
and keyframes. The complete MJB retains version-specific fields beyond that
JSON view. Plugin-bearing models are rejected after `mj_loadXML` returns; this
does not prevent compiler hooks or native plugin code from running during model
compilation. No `mjData` or simulation step is created. The receipt hashes the adapter, MuJoCo library, root MJCF, descriptor
and MJB. It explicitly does not claim to hash all referenced MJCF asset bytes.

`validate_usd(adapter, usd, variants)` opens the actual composed OpenUSD stage,
requires an active defined default prim, applies existing named variants to that
prim in an anonymous session layer, and checks composition errors, units, axis
and dependency resolution. Nested variants are selected incrementally and the
final selections are checked together. The adapter reports dependency layers,
resolved asset paths, rigid bodies and revolute joints. It does not save a
layer, convert USD to MJCF or construct a Newton model. The receipt hashes the
adapter and root USD; dependency paths are metadata, not hashes of their bytes.
Its `articulation_ir` additionally exposes native USD physics schema data for the
adjacent scene package. That IR explicitly retains unsupported importer semantics;
it is not a Newton-ready cooked model.

Build the MuJoCo adapter using real, installed headers:

```sh
cmake -S src/learning_aligned/producer_native/model/native -B target/apic-model-native -DMUJOCO_INCLUDE_DIR=/absolute/mujoco/include
cmake --build target/apic-model-native --target moonrobo_prepared_model
```

The optional OpenUSD adapter uses a C++ build with
`PXR_ENABLE_PYTHON_SUPPORT=OFF` and an installed `pxrConfig.cmake`:

```sh
cmake -S src/learning_aligned/producer_native/model/native -B target/apic-usd-native -DMOONROBO_PREPARE_MUJOCO=OFF -DMOONROBO_PREPARE_OPENUSD=ON -Dpxr_DIR=/absolute/openusd/lib/cmake/pxr
cmake --build target/apic-usd-native --target moonrobo_prepared_usd
```

These are build instructions, not commands run as part of the migration.
The C++ source rejects a Python-enabled OpenUSD configuration at compile time.
Native shared-library dependencies and resolver plugins must come from that
same Python-free installation. No SDK, Kit, IsaacLab, Warp JIT or CUDA operation
is performed by this package. Newton scene construction and Warp graph capture
remain separate producer stages and cannot be inferred from this descriptor.

Validation performed during this change: native MoonBit typechecking and
syntax-only checks of the C loader and C++ adapter against the real installed
MuJoCo headers. OpenUSD APIs were checked against the available upstream source
headers; no generated `pxr.h`/configured OpenUSD installation was available for
a complete syntax check. No model compilation, USD opening, conversion, tests,
simulation or numerical equivalence checks were run.
