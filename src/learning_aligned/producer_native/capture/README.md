# Native capture of one concrete ported kernel

`capture(CaptureConfig)` is an explicit offline execution command. It loads an
already compiled fixed G1 kernel image, allocates and uploads its raw buffers,
executes one CUDA kernel while recording APIC operations, and saves a `.wrp`.
It does not compile code, initialize IsaacLab/Newton/Kit, run a physics solver,
or produce `moonrobo.aligned-apic-bundle.v1`.

The output format is `moonrobo-concrete-kernel-apic-capture-v1`. It retains the
actual compiled image under `kernel_modules/` (the companion directory for
`kernel.wrp` required by the native loader), generated source, original compiled receipt, initial raw
buffers, observed post-capture buffers, exact named arguments and graph hashes.
Observed output is an execution record, not an equivalence test. Native replay
has not been validated by this command.

The compiled directory must come from `compile-kernels`, with its exact manifest
SHA supplied explicitly. Before CUDA initialization the runner recomputes the
typed specialization, source and entry metadata, verifies actual source/image/
raw-buffer hashes, retains the compiled artifact's NOTICE, and validates all array bounds, shapes, strides, primitive
types and bounded gather/scatter permutations. Owned buffers support float32, int32 and
canonical bool bytes. `transformf` and `spatial_vectorf` arguments are typed views
over float32 storage. Writable arguments require distinct owners and disjoint
rows/elements; arbitrary pointer-bearing blobs, gradients and mesh handles are
outside this runner's scope.

Each buffer specifies `{name,path,sha256,scalar_type}`. Each named array argument
is `{buffer,shape,byte_strides,offset_bytes}`; int32 and bool scalar arguments are
plain JSON values. Every output buffer also needs explicit initial bytes. For
example, a `root-pose-mask` request uses the named arguments `data`, `env_mask`
and `root_link_pose_w`, with one-dimensional transform/bool/transform views and
byte strides 28/1/28 respectively. Buffer and argument names are semantic IDs;
snapshot file names use generated numeric indices.

Configuration fields are `dispatch_plugin`, `writer_plugin`, `warp_library`,
`device_ordinal`, `architecture`, `compiled_directory`,
`compiled_manifest_sha256`, `kernel_key`, `buffers`, `arguments`
and a fresh `output` directory. The explicit
architecture must match both the compiled target and actual CUDA device.

APIC-only recording executes the launch immediately. Therefore every native
allocation is registered and snapshotted **before** recording starts. Capturing
post-launch bytes as initial state would apply the update twice when replayed.
The context, kernel, buffers and writer remain owned through graph save; the
native recording scope contains no asynchronous filesystem yield.

The native APIC loader uses the actual image and embedded kernel metadata and
does not require a Warp Python `.meta` companion. This lowerer does not generate
one. No pseudo `.meta` is manufactured. The artifact is outside the complete
aligned-bundle contract because it contains one concrete kernel rather than the
four role graphs and their complete scene/model/context/physics closure.

Source checks, interface generation and formatting are permitted during this
migration. Tests, CUDA initialization, compilation and capture remain deferred.
