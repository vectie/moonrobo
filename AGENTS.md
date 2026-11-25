# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## External E1 neck motors

- Read [the neck control incident and runbook](docs/E1_NECK_CONTROL.md) before
  changing or running the external STS3215 neck controller.
- Use `src/neck_control` and `cmd/neck_control`. Do not use ad-hoc serial
  position writes, the legacy XLeRobot startup path, or saved SRAM-block
  restoration for this neck.
- Treat every goal-position write as potentially energizing the servo, even
  after torque-off. Raw position zero is not the saved neutral pose; speed
  zero in position mode is maximum speed.
- Preserve the checked startup order, fresh-feedback and rate bounds,
  terminal release, durable fault/replay protection and write-before-send
  audit records. No cleanup or reconnect path may replay a stored target.
- Run the neck regression tests when modifying this path. Prefer read-only
  hardware verification; physical movement must retain the user's authorized
  scope and the existing MoonRobo execution gate. Do not request the same
  authorization again when it is already present in the session.
- Joystick sessions use the commissioned left Joy-Con, neutral-before-arm,
  held ZL, fresh input and bounded one-tick steps. Only the input-only monitor
  may reopen input automatically; a physical session must fault on input loss.
