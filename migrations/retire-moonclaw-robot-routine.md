# Retire the MoonClaw robot-routine endpoint

Replace calls to `POST /v1/robot/routine/run` with a MoonFlow work item bound to
one of the manifest operations in `pack.json`.

The compatibility mapping is:

| Historical intent | Pack operation |
| --- | --- |
| Import/build the robot design | `robot.integrate-digital-model` |
| Inspect whether robot work can proceed | `robot.readiness.inspect` |
| Submit an agent-authored goal | `robot.command.submit-governed` |

There is intentionally no generic `run robot routine` operation. MoonClaw may
reason through its generic tool runtime, while MoonRobo owns every robot-domain
operation and all safety/effect decisions.
