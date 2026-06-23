#!/usr/bin/env python3
"""SDK E1 high-control command writer.

The MoonBit bridge writes one validated command envelope to a JSON file. This
process watches that file and publishes the command through the SDK high-control
binding. Use --dry-run for local validation without importing the SDK.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any


REQUIRED_FIELDS = {
    "intent_id",
    "capability",
    "action",
    "action_code",
    "vertical",
    "horizontal",
    "duration_ms",
    "data",
}


def fixture_command() -> dict[str, Any]:
    return {
        "intent_id": "intent-self-check",
        "capability": "control.high.walk",
        "action": "WALK",
        "action_code": 0,
        "vertical": 0.1,
        "horizontal": 0.0,
        "duration_ms": 1000,
        "data": 0,
    }


def validate_command(command: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED_FIELDS - set(command.keys()))
    if missing:
        errors.append(f"missing fields: {','.join(missing)}")
    if str(command.get("action", "")) not in {"WALK", "RUN", "DEFAULT"}:
        errors.append("action must be WALK, RUN, or DEFAULT")
    for key in ("vertical", "horizontal"):
        try:
            float(command.get(key))
        except Exception:
            errors.append(f"{key} must be numeric")
    for key in ("action_code", "duration_ms", "data"):
        try:
            int(command.get(key))
        except Exception:
            errors.append(f"{key} must be integer")
    return errors


def load_command(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        loaded = json.load(handle)
    if not isinstance(loaded, dict):
        raise ValueError("command JSON must be an object")
    errors = validate_command(loaded)
    if errors:
        raise ValueError("; ".join(errors))
    return loaded


def live_controller(sdk_root: Path) -> Any:
    build_dir = sdk_root / "build"
    sys.path.insert(0, str(build_dir))
    dds_path = sdk_root / "config" / "dds.xml"
    os.environ.setdefault("CYCLONEDDS_URI", f"file://{dds_path}")
    from highcontrol_py import ControlCmd, HighController  # type: ignore

    controller = HighController.instance()
    controller.init()
    return controller, ControlCmd


def publish_command(
    command: dict[str, Any],
    controller: Any,
    control_cmd: Any,
    dry_run: bool,
) -> None:
    action = str(command["action"])
    vertical = float(command["vertical"])
    horizontal = float(command["horizontal"])
    data = int(command["data"])
    if dry_run:
        print(
            json.dumps(
                {
                    "published": False,
                    "dry_run": True,
                    "intent_id": command["intent_id"],
                    "action": action,
                    "vertical": vertical,
                    "horizontal": horizontal,
                    "data": data,
                },
                separators=(",", ":"),
            ),
            flush=True,
        )
        return
    sdk_action = getattr(control_cmd, action)
    controller.publish_cmd(vertical, horizontal, sdk_action, data)
    print(
        json.dumps(
            {
                "published": True,
                "intent_id": command["intent_id"],
                "action": action,
            },
            separators=(",", ":"),
        ),
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish SDK E1 high-control commands")
    parser.add_argument("--input", default="", help="command JSON file to read/watch")
    parser.add_argument("--watch", action="store_true", help="watch --input for changes")
    parser.add_argument("--dry-run", action="store_true", help="validate without SDK publish")
    parser.add_argument("--sdk-root", default="../sdk", help="path to SDK repository")
    parser.add_argument("--poll-ms", type=int, default=50)
    parser.add_argument("--self-check", action="store_true", help="validate fixture command")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_check:
        errors = validate_command(fixture_command())
        if errors:
            for error in errors:
                print(error, file=sys.stderr)
            return 1
        print("ok")
        return 0
    if args.input == "":
        print("--input is required", file=sys.stderr)
        return 2
    controller = None
    control_cmd = None
    if not args.dry_run:
        controller, control_cmd = live_controller(Path(args.sdk_root).resolve())
    path = Path(args.input)
    last_signature: tuple[int, int] | None = None
    if args.watch and path.exists():
        stat = path.stat()
        last_signature = (int(stat.st_mtime_ns), int(stat.st_size))
    while True:
        if path.exists():
            stat = path.stat()
            signature = (int(stat.st_mtime_ns), int(stat.st_size))
            if signature != last_signature:
                command = load_command(path)
                publish_command(command, controller, control_cmd, args.dry_run)
                last_signature = signature
        if not args.watch:
            return 0
        time.sleep(max(args.poll_ms, 1) / 1000)


if __name__ == "__main__":
    raise SystemExit(main())
