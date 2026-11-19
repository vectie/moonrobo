# Native Warp CUDA dispatch

MoonBit calls this package's C ABI plugin, which resolves the official Warp
1.17.0 native API. There is no CPython link/import. The original producer and its
upstream physics dispatch remain available. The new package is an execution
backend for genuine compiled entrypoints, not a replacement Newton solver. The
dispatch plugin ABI is version 3, including compiled kernel rank, typed CUB
primitives, immutable partitions and actual conditional/outer graph ownership.

CMake accepts `WARP_NATIVE_INCLUDE_DIR` pointing to actual upstream `warp/native`
headers. The plugin uses header-derived function pointer types and actual
`APICLaunchInfo`, `APICLaunchParamRecord`, `APICLaunchPtrLocation` and
`wp::launch_bounds_t<N>` definitions. Static assertions compare the array
by-value descriptor size, alignment and field offsets with real
`wp::array_t<float>`. A supplied runtime must report exactly Warp `1.17.0` and
provide the real CUDA/APIC symbols.

## Context and resource ownership

`Context::borrow(plugin, warp_library, context, stream, arch?)` does not initialize
Warp, create a CUDA context or take ownership of the supplied context/stream.
If architecture is omitted, native device/context query APIs obtain it. An empty
borrowed wrapper's close only releases its library reference; it never
synchronizes or destroys the upstream context. The external owner must remain
alive through all operations, child handles and any captured graph's use. The
caller verifies that the supplied Warp library is the same loaded library owning
the borrowed pointers, as the hybrid producer does.

`Context::create` is an explicit offline action: it calls `wp_init`, creates a
CUDA context and its stream. It is never called by import, metadata checks or
availability checks. Neither constructor has been executed during this change.

Native buffers and loaded modules belong to a shared resource arena. `Buffer`
and `Kernel` retain that arena, including its Warp library. Closing one handle
does not invalidate other live children. The arena retains allocations/modules
until its last native owner is released, then synchronizes before freeing them.
Callers must keep the Context alive for an external recorded graph's complete
lifetime, since CUDA graphs can retain pointers without owning these resources.
If a finalizer encounters active stream capture, or a failed partial capture
has poisoned the session, it deliberately retains the native resources/library
rather than freeing capture inputs; this is misuse containment, not a resource
reclamation strategy. All operations run on the OS thread that opened the context.

Buffer allocation, module loading, host upload/download and synchronization are
forbidden during active capture. Upload/download synchronize before borrowed
host storage can be released. Parameter buffers stay alive for the complete FFI
call; the shared arena keeps their device storage stable afterward.

## Kernel arguments and actual launch

`Context::load_kernel` calls `wp_cuda_load_module`, resolves supplied forward and
optional backward symbols with `wp_cuda_get_kernel`, and configures genuine
shared-memory requirements. Inputs are actual image paths and compiler-provided
module hashes, entrypoints and launch metadata; no placeholder kernel is used.
The required `kernel_dim` comes from the compiled specialization. A launch whose
rank differs is rejected before constructing its bounds or calling CUDA, so a
different `launch_bounds_t<N>` layout cannot be silently substituted.

`Kernel::launch` constructs the actual `wp::launch_bounds_t<1..4>` argument,
followed by the declared forward arguments and optional matching adjoint
arguments. Shape multiplication, argument counts, byte spans, alignment and
relocation slots are bounded. `Argument::boolean` is a one-byte C++ bool;
MoonBit FFI Bool's int32 layout is not used for CUDA argument values.

`Argument::array` constructs the real Warp array descriptor from an owned
Buffer, shape, nonnegative byte strides, element width and optional gradient.
This convenience descriptor uses `flags=0`, without retained-gradient semantics;
retained-gradient layouts require explicit compiler-provided value/relocation
metadata. The current concrete runner does not launch adjoints.
The full reachable span is checked against the actual allocation. Native
packing adds data/gradient relocations and registers the real base allocations
with the active APIC state. The explicit value-blob API supports scalar,
vector/matrix and struct layouts only when their compiler layout is supplied;
every pointer field must have a declared relocation. Raw external handle
relocations require the caller to retain the actual mesh/handle owner.

The small `MRL1` byte transport is only a bounded MoonBit-to-plugin call format;
it is not an APIC serializer. The plugin constructs the official vendor records,
including separate forward/adjoint records and per-value relocation slices,
and calls `wp_cuda_launch_kernel` with a real `APICLaunchInfo` pointer. During
APIC recording, it also registers genuine module/kernel metadata through the
official C API. CUDA launches execute or join an active CUDA graph as well as
recording the APIC operation; they are never treated as metadata-only calls.

For APIC-only recording without a CUDA stream graph capture, the live launch
mutates device data immediately. Register and snapshot every input/output buffer
with the authoring Writer **before** `Writer::begin`, then launch using its actual
`state_pointer`. Otherwise save-time snapshots would capture post-launch state
and replay could apply the operation twice. The official CUDA save path keeps
already registered initial snapshots and only fills unsnapshotted regions.
Native APIC loading uses the embedded entrypoint/shared-memory records and
direct CUDA image loading; unlike Python's module-loading layer, that native
path does not require a companion `.meta` file. Actual image bytes and complete
kernel launch metadata still must be retained beside the `.wrp` file.

## Existing SDK storage

`copy_external` and `zero_external` call the official APIC-aware
`wp_memcpy_d2d`/`wp_memset_device`. They do not use untracked raw CUDA calls.
Their `capture_state` must equal the actual active device APIC state. A zero
state requires no active APIC or CUDA stream capture. The hybrid caller retains
both real storage owners, validates same-device layout/capacity, and registers
base arrays with the upstream recorder before invoking these operations. Raw
addresses cannot prove ownership or allocation size inside this C ABI; only
span overflow and overlap can be checked here.

## Deferred verification

MoonBit check/info/fmt and syntax-only compilation against the real pinned
headers are permitted without loading libraries. Pure argument-transport,
typed-span and actual partition-value test
sources were added, but no tests have been run. No context initialization,
allocation, image load, JIT, launch, capture or export has been executed. Hardware
execution, generated kernel ABI parity, APIC replay and numerical equivalence
remain pending. The package alone does not establish a Python-free full G1
training or IsaacLab/Newton physics pipeline.

## Native CUB scan and segmented sort

`Buffer::typed_view` retains the actual Buffer and checks type alignment, full
reachable byte span, positive byte stride and component width. `Context::scan`
calls the actual `wp_array_scan_{int,int64,float,double}_device` entrypoint with
the upstream byte-stride/component ABI, covering inclusive/exclusive sums.
Input/output spans must not overlap. The native scope binds the actual context
and stream required by these implicit-current-context APIs, then restores both.

`Context::segment_partition` validates actual host int32 boundary values and
uploads immutable native-owned storage **before capture**. Values start at zero,
end at the declared item count, are monotone, and remain in `[0,count]`.
Repeated boundaries/empty segments are supported; the bounded transport accepts
up to 1,048,576 segments. Neither MoonBit nor the public C ABI exposes a mutable
Buffer or address for this private allocation. The exact uploaded host bytes
are retained and synchronously copied into the APIC initial-data registration
when a sort is recorded, without device readback during capture.

`Context::segmented_sort_pairs` accepts this opaque `SegmentPartition`, I32 or
F32 keys, and I32 values. It requires at least `2*count` contiguous key and value
elements so the real CUB double buffers retain their scratch half. It calls
`wp_segmented_sort_pairs_{int,float}_device` with the genuine `nsegments+1`
inferred-end partition. Arbitrary mutable or GPU-generated boundary views are
not accepted: a verified producer/provenance contract for dynamic partitions
remains necessary before that path can be enabled safely. Fixed SAP world
partitions can use this actually validated host partition API.

The Warp primitive APIs return void. The wrapper refuses a preexisting vendor
error string and checks the vendor error immediately afterward; it does not
silently treat a failed CUB operation as success. Captured primitive failure
poisons the session. CUDA synchronization remains an explicit operation outside
capture, so delayed device errors still require the deferred hardware checks.

## Genuine dynamic graph control flow

`Context::capture_graph` owns a real outer CUDA graph using
`wp_cuda_graph_begin_capture` / `wp_cuda_graph_end_capture` with the actual
`WP_CUDA_GRAPH_CAPTURE_MODE_THREAD_LOCAL` constant, matching Warp's default.
An existing live APIC Writer remains caller-owned throughout the synchronous
callback. Returned `Graph` retains the shared allocation/module arena.
`Graph::launch` lazily calls `wp_cuda_graph_create_exec` and launches that actual
executable; destruction uses the official graph/executable destroy APIs and
completion synchronization. These are explicit runtime operations, never
availability probes.

Inside that outer graph, `Context::capture_if` and `capture_while` require one
retained int32 condition element, the exact active nonzero APIC state, and CUDA
toolkit/driver 12.4 or newer. The wrapper inserts actual conditional graph nodes,
pauses the parent, captures each child, checks the body's supported node types,
then resumes the parent. It records the corresponding genuine APIC IF/WHILE
using `wp_apic_begin_branch`, `wp_apic_end_branch` and
`wp_apic_record_conditional`.

Each synchronous callback runs once to **construct** the body graph. Runtime
WHILE execution rereads the device condition after each body, using the real
`wp_cuda_graph_set_condition` update. The body is responsible for changing the
condition so the loop terminates. There is no fixed-iteration substitution,
host-side guessed condition, or Python fallback. APIC-only conditional capture
without an active CUDA outer graph is rejected, as are unsupported driver/
toolkit versions and unsupported conditional body nodes. Warp may compile its
own built-in CUDA condition-update kernel when this explicit runtime API is
eventually used; that path remains native and has not been executed here.

On callback/driver failure, partial APIC branch bytes are removed, branch bodies
are freed, and the parent CUDA capture is restored as far as the vendor API
permits. An already inserted conditional node cannot be undone. The context is
poisoned and the parent graph must be discarded; the owned outer-graph wrapper
discards it instead of returning a successful graph. Native resources are
conservatively retained after poisoned capture failures. Keep the external APIC
Writer/state owner alive throughout callbacks; callbacks must not close or
replace that recording. Asynchronous callbacks and prebuilt Graph branch bodies
are deliberately unsupported.
# Independent context tokens

`Context.retain()` creates a new token over the same native `shared_ptr<Device>`;
it does not create, initialize or independently borrow a CUDA context. Closing
the original token releases only that token. The real owning context/stream,
arena allocations and loaded library remain alive until the last retained
token/child owner is released. Native thread affinity still applies. If the
original context was externally borrowed, its true external CUDA owner must
still outlive every token and graph.

This is the additive optional `mrd_context_retain` entry point on dispatch ABI 3.
Older ABI-3 adapters retain their existing behavior; calling the new method on
one fails explicitly for the missing symbol and does not poison the original
context token. No different adapter or new context is silently substituted.

`Kernel.suggested_block_size(shared_memory_bytes?=0)` calls Warp's actual
`wp_cuda_get_suggested_block_size` outside capture and returns both block size
and minimum grid size. It uses the optional additive ABI-3
`mrd_suggested_block_size` symbol; unsupported adapters fail explicitly. The
query is an explicit native API call and is never performed by static checks
or by source-only host contact planning.
