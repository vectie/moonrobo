# Native Warp APIC authoring

This package connects MoonBit to the official Warp 1.17.0 C API through an
explicitly supplied C ABI plugin. It neither embeds CPython nor imports Python
modules. The original `learning_aligned/producer` implementation remains intact.

The plugin is compiled from `native/warp_writer.cpp` against actual upstream
`warp/native/warp.h` and `apic.h`, with APIC format 15 checked at compile time.
CMake requires `WARP_NATIVE_INCLUDE_DIR`; the authoring plugin ABI is version 2,
including the synchronous borrowed `state_pointer` accessor. There are no copied vendor function
prototypes and no link to a Python library. A deployment supplies both the
resulting `moonrobo_warp_authoring` shared library and its explicit Warp shared
library path. MoonBit's `loader.c` dynamically resolves the plugin ABI; the plugin
resolves the official Warp API with header-derived function pointer types.

`Writer::borrow(plugin_path, warp_library, state, context, stream, arch)` borrows
a finished capture. It calls the pure `wp_version` query and requires exactly
`1.17.0`; it never calls `wp_init`, begins/ends recording, creates a CUDA context,
or destroys the borrowed state/context/stream. The state, allocations, mesh
objects, module binaries and capture-owning graph must remain alive through all
snapshot/registration/save calls. The supplied Warp library must be the same
loaded library that owns that state. The hybrid producer enforces this identity;
raw C ABI callers retain that responsibility. Methods run on the opening OS
thread. Closing releases the wrapper and its own dynamic-library reference only.

The public methods register actual module/kernel metadata, bindings, memory
snapshots, pointer relocation locations, and official mesh registrations.
CUDA snapshots use `wp_memcpy_d2h` on the supplied context/stream followed by
context synchronization/error checking before passing the host bytes to
`wp_apic_register_memory_region`, which copies them. Transient CUDA graph-scoped
regions register their size/type without attempting to dereference a dead device
allocation. A relocation stride of zero means one pointer, as in upstream Warp;
positive strides must hold an entire native pointer. A region must first be
registered or snapshotted so the wrapper can check the pointer offset against
its capacity; positive strides are also bounded to prevent the upstream replay
iteration from overflowing. `save` calls
`wp_apic_state_save` and refuses an empty operation stream.

`Writer::create` provides an additional owned recording path. Creating is an
explicit offline action and calls `wp_init("1.17.0")`. For CPU captures,
`host_region` copies initial bytes into stable native-owned storage before
`begin`; `host_memset` and `host_copy` call the real `wp_memset_host` and
`wp_memcpy_h2h` recording hooks. `end` finalizes that actual operation stream.
These are real memory-operation captures, not a replacement Newton solver or
Python-free IsaacLab scene builder. CUDA state creation accepts a caller-owned
live context/stream; constructing and launching all Newton solver kernels still
requires the separate upstream integration. No fake physics operations or
handwritten APIC binary serializer are provided.

No build, library load, `wp_init`, GPU call, graph save, or test execution is
needed for `moon check` or C/C++ syntax-only checking. Numerical replay and
producer-equivalence validation remain deferred until the machine is available.
