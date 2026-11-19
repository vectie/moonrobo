# Native G1 MJCF → USDA conversion

`native/usd_converter.cpp` loads a genuine compiled MuJoCo model and writes a
standard USDA articulation with UsdGeom and UsdPhysics schemas. It emits compiled
mesh vertices/triangles, primitive geometry, local geometry poses, rigid-body
rest transforms, masses, COM/principal inertia axes, hinge/fixed joint frames,
joint limits, collision material friction and explicit disabled-self-collision
filters, including same-weld-cluster exclusions. Quaternion/joint axes and
angular units are converted explicitly.
Local nondefault `geom_rgba` overrides the material color as in MuJoCo. Massless
fixed frames, including the acquired G1's IMU/camera links, remain named Xforms
under their nearest massive rigid-body owner; geometry/rest transforms are
preserved without inventing mass or enabling USD geometry-based mass inference.
Moving descendants attach their joints to that actual rigid-body owner.

The implementation is bounded to the original G1 floating-base, 29-hinge model.
Missing assets, nonzero hinge reference coordinates, unsupported joints/geoms,
textured materials, invalid compiled meshes and collision ellipsoids fail
explicitly. A collision ellipsoid is not represented by a nonuniformly scaled
USD sphere: [UsdPhysics sphere collision uses the greatest scale axis](https://openusd.org/release/api/usd_physics_page_front.html),
which changes the physical shape. Visual-only ellipsoids retain scaled-sphere
geometry.

Build `native/CMakeLists.txt` with real `MUJOCO_INCLUDE_DIR` and
`MUJOCO_LIBRARY`. `usd.convert_usd` dynamically loads the resulting converter;
`cmd convert-usd --library CONVERTER_LIBRARY --mjcf SOURCE --usd-output NEW.usda`
records input/output/library SHA256 and collision configuration in a separate
receipt. The destination must be new and have `.usda` extension. No Python,
Isaac process or simulator integration step is involved. Conversion loads and
forwards the compiled rest state to obtain transforms; it does not step physics.

The optional `MOONROBO_OPENUSD_VALIDATOR` CMake target uses actual OpenUSD
libraries to parse the output and check articulation/body/joint topology and
mesh indices. It is a structural validator, not a mass/frame/limit numerical
equivalence proof or an Isaac importer result. Importing this standard USD into
the pinned Newton runtime must still pass canonical joint-order validation.
This output has one standard physical description and no `Physics` variant set.
The offline APIC producer must explicitly use `usd_variants: {}` for this file;
legacy vendor assets may request their actual `Physics: "mujoco"` selection.
The producer validates requested sets/options rather than relying on the SDK's
warning-and-continue behavior for absent sets, then records the mapping in the
artifact identity.

The converter was syntax-checked against genuine installed MuJoCo headers.
No converter/validator was executed. The OpenUSD validator was not compiled on
this host because only an unconfigured OpenUSD source tree is available.
No claim is made of byte-identical output or dynamic equivalence to the
preserved vendor MJCF importer.
