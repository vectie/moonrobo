# Native NVRTC compilation

This package connects MoonBit to NVRTC's public C API through a dynamically
loaded, explicitly selected library. It requires neither CPython nor a CUDA
driver context. No library search, installation or compilation occurs until an
application explicitly calls `Compiler::open` / `Compiler::compile`.

`compile_artifact(request : ArtifactRequest) -> Json` is asynchronous and reads
the following JSON contract:

```json
{
  "nvrtc_library": "/absolute/path/libnvrtc.so",
  "source_path": "/absolute/path/already-generated.cu",
  "program_name": "already-generated.cu",
  "headers": [
    {"include_name": "local.h", "path": "/absolute/path/local.h"}
  ],
  "options": ["--gpu-architecture=compute_90", "--std=c++17"],
  "kind": "ptx",
  "output": "/absolute/path/fresh-module-output"
}
```

Use `"cubin"` with a real `sm_...` architecture to request CUBIN; NVRTC rejects
unsupported architectures and options directly. Neither option nor architecture
is silently changed. Includes passed through `headers` are in-memory NVRTC
headers; their names may contain logical subdirectories but never control output
paths. Every source/header is saved under a fixed local filename, and the
manifest records its original include name and SHA-256. The compiler file, its
version, options, output bytes and successful compiler log are recorded too.
The manifest explicitly does not attest transitive native dependencies or
include files implicitly found through `-I` / compiler defaults.

Compilation failures raise `CompileError::Failed(message~, log~)` with NVRTC's
actual diagnostic log and produce no output directory. Successful image retrieval
always destroys its NVRTC program; the library and temporary image/log buffers
have MoonBit external-object finalizers. Partial filesystem writes leave no
completion manifest and are not automatically removed or overwritten.

This is a real **generated CUDA source → PTX/CUBIN** step. Warp's Python AST
translation and type specialization, Newton/MJWarp kernel source generation,
kernel argument metadata, dispatch planning, model construction and APIC graph
capture are separate capabilities. This package does not fabricate `.meta`
files or claim that a compiled module is an APIC capture.

Source API reference: [NVIDIA NVRTC documentation](https://docs.nvidia.com/cuda/nvrtc/).
The development host has no NVRTC SDK header installed: the C stub has been
syntax checked with genuine `moonbit.h`, not checked against a fabricated NVRTC
header. Runtime compiler loading, CUDA compilation and artifact generation are
deferred with the other tests.

On a machine with an installed NVIDIA SDK, an additional **syntax-only** Clang/GCC
check can define `MOONROBO_NVRTC_VERIFY_HEADERS` and add the genuine SDK include
directory. The loader then uses `nvrtc.h` types and compile-time checks every
function-pointer signature against the SDK declaration. This mode has not been
executed on the current host and does not load any native library.
