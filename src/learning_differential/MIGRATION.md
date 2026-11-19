# Differential tooling migration status

The actual candidate adapters, strict sealed-fixture/capture protocol,
`cmd/reference_differential` CLI, 27 original-method fixture entries and schema
regressions are authored and native typechecked. The three independent C++
oracle sources passed syntax-only checking against installed Torch headers.
They were not compiled, linked, loaded or executed. No fixture, random sample,
training run, simulator step or differential comparison was generated or run.

[README.md](README.md) documents the schema, source/RNG/gradient/Adam binding,
commands and immutable exporter. [AUDIT.md](AUDIT.md) maps every one of the 54
methods in the nine retained aligned Python test files, including the 27
registered differential/Isaac cases and direct native unit/physics contracts.

The fixed candidate routes invoke actual production code: shared
`WorldModel::fit_fixed`/`Learner::update_policy_fixed` cores, production
quaternion/reward pullbacks, actual replay and reset sampling. Optional seams
expose supplied samples/permutations/FixtureMDP heads and actual Adam gradients;
default training still uses its original physical heads and native RNG.

Independent C++ equations are never labeled execution of original Python. The
12 original comparisons that execute sibling SMC functions require real
`executed-upstream-python` fixtures; none has been generated. Native Float64
outputs truthfully fail the original Float32 dtype/bitwise gate. These are
explicit unverified numerical/execution boundaries, with the original source
thresholds retained. The five original data unit cases and nine Isaac cases
have direct native tests and strict external capture routes, not an implicit
substitute simulator or newly fabricated upstream fixture.
