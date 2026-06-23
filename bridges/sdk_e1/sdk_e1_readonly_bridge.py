#!/usr/bin/env python3
"""Read-only SDK E1 sidecar scaffold.

This script emits the JSON snapshot consumed by the MoonBit `src/sdk_e1`
adapter. The default fixture mode needs no robot or SDK build. Live mode imports
`highcontrol_py` from the SDK build directory and uses only read APIs.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


JOINT_NAMES = [
    "arm_l1_joint",
    "arm_l2_joint",
    "arm_l3_joint",
    "arm_l4_joint",
    "arm_l5_joint",
    "leg_l1_joint",
    "leg_l2_joint",
    "leg_l3_joint",
    "leg_l4_joint",
    "leg_l5_joint",
    "leg_l6_joint",
    "arm_r1_joint",
    "arm_r2_joint",
    "arm_r3_joint",
    "arm_r4_joint",
    "arm_r5_joint",
    "leg_r1_joint",
    "leg_r2_joint",
    "leg_r3_joint",
    "leg_r4_joint",
    "leg_r5_joint",
    "leg_r6_joint",
    "waist_1_joint",
    "waist_2_joint",
]


def numeric_list(values: Any, length: int, default: float = 0.0) -> list[float]:
    result: list[float] = []
    for index in range(length):
        try:
            result.append(float(values[index]))
        except Exception:
            result.append(default)
    return result


def int_list(values: Any, length: int, default: int = 0) -> list[int]:
    result: list[int] = []
    for index in range(length):
        try:
            result.append(int(values[index]))
        except Exception:
            result.append(default)
    return result


def fixture_snapshot(frame_id: str, captured_at_ms: int) -> dict[str, Any]:
    return {
        "frame_id": frame_id,
        "captured_at_ms": str(captured_at_ms),
        "mode": 1,
        "telemetry_age_ms": 0,
        "joints": [
            {
                "motor_id": index,
                "position": index * 0.01,
                "velocity": 0.0,
                "torque": 0.0,
                "error": 0,
                "temperature": 0,
            }
            for index, _ in enumerate(JOINT_NAMES)
        ],
        "imu": {
            "orientation": [1.0, 0.0, 0.0, 0.0],
            "angular_velocity": [0.0, 0.0, 0.0],
            "linear_acceleration": [0.0, 0.0, 9.8],
        },
        "joy": {
            "axes": [0.0, 0.0],
            "buttons": [0] * 14,
        },
        "errors": [],
    }


def now_ms() -> int:
    return int(time.time() * 1000)


def frame_id_for(base: str, sequence: int, repeat: bool, single_shot: bool) -> str:
    if repeat or single_shot:
        return base
    return f"{base}-{sequence}"


def captured_at_for(explicit_ms: int | None) -> int:
    return now_ms() if explicit_ms is None else explicit_ms


def live_controller(sdk_root: Path) -> Any:
    build_dir = sdk_root / "build"
    sys.path.insert(0, str(build_dir))
    dds_path = sdk_root / "config" / "dds.xml"
    os.environ.setdefault("CYCLONEDDS_URI", f"file://{dds_path}")
    from highcontrol_py import HighController  # type: ignore

    controller = HighController.instance()
    controller.init()
    return controller


def live_snapshot(controller: Any, frame_id: str, captured_at_ms: int) -> dict[str, Any]:
    started = time.monotonic()
    mode = int(controller.get_mode())
    joint_state = controller.get_joint_state()
    imu = controller.get_imu_data()
    joy = controller.from_dds_get_joydata()
    elapsed_ms = int((time.monotonic() - started) * 1000)
    return {
        "frame_id": frame_id,
        "captured_at_ms": str(captured_at_ms),
        "mode": mode,
        "telemetry_age_ms": elapsed_ms,
        "joints": [
            {
                "motor_id": int(getattr(state, "motor_id", index)),
                "position": float(getattr(state, "pos", 0.0)),
                "velocity": float(getattr(state, "vel", 0.0)),
                "torque": float(getattr(state, "tau", 0.0)),
                "error": int(getattr(state, "error", 0)),
                "temperature": int(getattr(state, "temperature", 0)),
            }
            for index, state in enumerate(joint_state)
        ],
        "imu": {
            "orientation": numeric_list(getattr(imu, "ori", []), 4),
            "angular_velocity": numeric_list(getattr(imu, "angular_vel", []), 3),
            "linear_acceleration": numeric_list(getattr(imu, "linear_acc", []), 3),
        },
        "joy": {
            "axes": numeric_list(getattr(joy, "axes", []), 2),
            "buttons": int_list(getattr(joy, "button", []), 14),
        },
        "errors": [],
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Emit a read-only SDK E1 snapshot")
    parser.add_argument("--live", action="store_true", help="poll ../sdk highcontrol_py")
    parser.add_argument("--sdk-root", default="../sdk", help="path to SDK repository")
    parser.add_argument("--frame-id", default="sdk-e1-sidecar-frame")
    parser.add_argument(
        "--repeat-frame-id",
        action="store_true",
        help="reuse --frame-id for every emitted snapshot",
    )
    parser.add_argument(
        "--captured-at-ms",
        type=int,
        default=None,
        help="fixed capture timestamp; defaults to current time",
    )
    parser.add_argument(
        "--output",
        default="",
        help="write latest snapshot JSON atomically to this file",
    )
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="validate fixture snapshot shape and exit",
    )
    parser.add_argument("--once", action="store_true", help="emit one snapshot and exit")
    parser.add_argument("--interval-ms", type=int, default=100)
    return parser.parse_args()


def emit_snapshot(snapshot: dict[str, Any], output: str) -> None:
    text = json.dumps(snapshot, separators=(",", ":"))
    if output == "":
        print(text, flush=True)
        return
    path = Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(text + "\n", encoding="utf-8")
    tmp.replace(path)


def validate_snapshot_shape(snapshot: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if len(snapshot.get("joints", [])) != len(JOINT_NAMES):
        errors.append("snapshot must contain 24 joints")
    for index, joint in enumerate(snapshot.get("joints", [])):
        if int(joint.get("motor_id", -1)) != index:
            errors.append(f"joint {index} motor_id mismatch")
    imu = snapshot.get("imu") or {}
    if len(imu.get("orientation", [])) != 4:
        errors.append("imu orientation must contain 4 values")
    if len(imu.get("angular_velocity", [])) != 3:
        errors.append("imu angular_velocity must contain 3 values")
    if len(imu.get("linear_acceleration", [])) != 3:
        errors.append("imu linear_acceleration must contain 3 values")
    joy = snapshot.get("joy") or {}
    if len(joy.get("axes", [])) != 2:
        errors.append("joy axes must contain 2 values")
    if len(joy.get("buttons", [])) != 14:
        errors.append("joy buttons must contain 14 values")
    return errors


def main() -> int:
    args = parse_args()
    if args.self_check:
        errors = validate_snapshot_shape(fixture_snapshot("self-check", 0))
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("ok")
        return 0
    controller = live_controller(Path(args.sdk_root).resolve()) if args.live else None
    single_shot = args.once or not args.live
    sequence = 0
    while True:
        captured_at_ms = captured_at_for(args.captured_at_ms)
        frame_id = frame_id_for(
            args.frame_id,
            sequence,
            args.repeat_frame_id,
            single_shot,
        )
        snapshot = (
            live_snapshot(controller, frame_id, captured_at_ms)
            if controller is not None
            else fixture_snapshot(frame_id, captured_at_ms)
        )
        emit_snapshot(snapshot, args.output)
        if single_shot:
            return 0
        sequence += 1
        time.sleep(max(args.interval_ms, 1) / 1000)


if __name__ == "__main__":
    raise SystemExit(main())
