#!/usr/bin/env python3
"""Read-only SDK E1 sidecar scaffold.

This script emits the JSON snapshot consumed by the MoonBit `src/sdk_e1`
adapter. The default fixture mode is deterministic and needs no robot or SDK
build. Live mode imports `highcontrol_py` from the SDK build directory and uses
only read APIs.
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
    parser.add_argument("--captured-at-ms", type=int, default=0)
    parser.add_argument("--once", action="store_true", help="emit one snapshot and exit")
    parser.add_argument("--interval-ms", type=int, default=100)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    controller = live_controller(Path(args.sdk_root).resolve()) if args.live else None
    while True:
        snapshot = (
            live_snapshot(controller, args.frame_id, args.captured_at_ms)
            if controller is not None
            else fixture_snapshot(args.frame_id, args.captured_at_ms)
        )
        print(json.dumps(snapshot, separators=(",", ":")), flush=True)
        if args.once or not args.live:
            return 0
        time.sleep(max(args.interval_ms, 1) / 1000)


if __name__ == "__main__":
    raise SystemExit(main())
