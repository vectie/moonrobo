# Authored schema resolution and pure equality storage

This package ports a finite part of pinned Newton's schema resolver and MuJoCo
equality authoring. Original implementations remain unchanged. No tests,
resolution examples, equality preparation, native upload or model compilation
were executed during this migration.

`decode_schema` / `resolve_schema` accept `SchemaRequest` with resolver names in
priority order, one prim type, **authored-only** attributes, queried keys and
caller defaults. The precedence is the actual first transformed authored value,
then caller default, then first non-None mapping default. Authored false/zero
remain present. Mapping defaults use their transformer, not their custom getter;
defaults have no supplying authored resolver. Collection occurs on first
successful use of a resolver, with namespaced nulls preserved. The builtin
Newton/Mjc/PhysX maps are deliberately finite; unimplemented logical keys,
custom resolvers and duplicate resolver names are rejected.

The supported maps cover scene iterations/frequency/gravity, selected joint
armature/damping/friction/limits, shape margin/gap/mass model/hull limits and
contact coefficients, material contact/friction coefficients, rigid damping,
and articulation self-collision. Actual getters include PhysX contactOffset
minus restOffset, PhysX's unset restOffset, Mjc effort-range auto limits, Mjc
raw/standard solref mirrors, timestep reciprocal and shell/solid conversion.
Mapping keys are listed in `schema.mbt`. JSON `"+inf"` / `"-inf"` are explicit
numeric sentinels, not silently substituted finite values. This layer does not
perform USD composition, schema registration, material binding, unit conversion
in `_UsdJointProperties`, fixed-joint collapse or complete vendor import.

`decode_equalities` / `prepare_equalities` accept explicit topology/worlds,
actual exported MuJoCo names and pure connect/weld/scalar-joint rows. They
implement public helper validation, padded quartic coefficients, shared/global
world ownership and contiguous world starts. Managed objtype and target fields
follow the public helpers; custom columns and loop/mimic projection are absent.
Values are rounded to actual Newton float32 storage before being promoted into
MuJoCo authoring data. Array owners include every canonical equality-frequency
numeric field and shape-stable zero-row arrays; labels remain metadata.
The XML contains all supplied rows, matching the non-separated model authoring
branch. Selecting only the first local world plus global rows for a separated
MuJoCo model remains the caller's explicit preparation step and is not inferred
by this API.

Newton relpose is xyz+xyzw. A missing weld relpose retains public Newton's
`[0,1,0,0,0,0,0]` compiler-inference sentinel. It is not normalized to identity.
Explicit zero-quaternion weld poses also remain pending inference. Exported
`prepared.mjs_equality_data` and `mjs_authoring` describe values **before** native
compiler inference, not compiled model `eq_data`. Their object kinds describe
referenced entities. The escaped `equalities.xml` is an actual MJCF include
containing an equality section, suitable for a later explicit native model
compiler with the caller's real body/joint names. This package does not create
an MJB or perform Newton-to-MuJoCo model conversion.

`schema_artifact(request, output)` writes a fresh request/result/hash receipt.
`equality_artifact(request, output)` writes true little-endian raw arrays, XML,
request and hash receipt. `upload(prepared, context)` explicitly connects the
array bytes to the existing native Warp C allocation/upload API; it is never
called by either artifact writer. The context is caller-owned and retained;
closing DeviceArrays closes its child handles, not the caller's context. Empty
arrays allocate nothing and cannot be dispatched. Snapshot metadata and copied
shape arrays do not let callers mutate the retained host layout.

Full Newton construction, compiler reference constants, constraint Jacobians,
Hessians and solves remain unimplemented. This package makes no numerical,
physics or learning equivalence claim. Six pending regression sources cover
priority/falsey values, fallback transforms, physical getter formulas, weld
sentinels, polynomial padding, ownership and cross-world rejection.

Source identities and Apache-2.0 attribution are recorded in `sources.json` and
the central cooking/device evidence. All sources use Newton revision
`71eeba16a717d4dcf0b9dd7056a7b6f863054dc3`.
