"""Audit a completed shadow hold and its experimental effort seed; no sockets."""
import json
import pathlib
import sys
from shadow_effort_validation import PositionHoldAudit, validate_shadow_effort, verify_seed_capture


def main():
    directory, output = map(pathlib.Path, sys.argv[1:])
    assert not output.exists()
    session=json.loads((directory/"session.json").read_text())
    planner=json.loads((directory/"planner.json").read_text())
    assert session["kind"]=="shadow" and session["command_writers_created"] is False
    assert session["planner_status"]==session["sender_status"]==0
    assert planner["stage"]=="hold" and planner["software_stage_completed"] is True
    assert planner["moving_slots"]==[] and planner["active_ms"]>=1000
    baseline=seed=None
    stopped=False
    count=0
    position=PositionHoldAudit()
    position_mode=None
    final_meta=None
    for line in (directory/"targets.ndjson").open():
        row=json.loads(line)
        if row["kind"]=="stop":
            assert row["reason"]=="stage complete" and not stopped
            stopped=True
            continue
        assert not stopped and row["stage"]=="hold" and row["sequence"]==count
        active_position=row.get("position_hold_shadow") is not None
        if position_mode is None:position_mode=active_position
        assert active_position==position_mode
        if position_mode:
            position.observe(row)
            final_meta=row["position_hold_shadow"]
            count+=1
            continue
        current=validate_shadow_effort(row,baseline)
        if baseline is None:
            seed=current
            verify_seed_capture(seed,directory/"status.ndjson")
            baseline=row["motors"]
        assert current==seed
        count+=1
    assert stopped and count>0 and planner["reported_leg_effort_shadow"]==seed
    if position_mode:
        assert planner["active_ms"]>=15000
        position.verify_capture(directory/"status.ndjson")
        assert planner["position_hold_shadow"]==final_meta
        assert planner["fixed_position_records"]==24 and planner["fixed_motor_records"]==12
    report=dict(passed=True,
                command_writers_created=False,powered_takeover_qualified=False,
                target_heartbeats=count,fixed_records=12 if position_mode else 24,
                fixed_position_records=24,reported_leg_effort_shadow=seed,
                position_feedback_shadow=bool(position_mode),
                maximum_bias_nm=position.maximum_bias_nm if position_mode else None,
                scope="position-feedback hold shadow" if position_mode else "reported-effort hold shadow")
    output.write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))


if __name__=="__main__":main()
