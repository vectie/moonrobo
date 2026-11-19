"""Compile the retargeting robot description into a native MuJoCo model.

The physics compilation follows smc's URDF conversion (MIT; SMC_LICENSE).
No proprietary simulator is required. A separate scene adds the floor and
the same implicit joint PD gains, effort limits and motor armatures.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

import mujoco

from .robot import G1_JOINT_NAMES, motor_of, _kp, _kd


def compile_description(description_dir, *, self_collisions=True):
    folder = Path(description_dir).resolve()
    source = folder / "g1_29dof_rev_1_0.urdf"
    root = ET.parse(source).getroot()
    for child in list(root.findall("mujoco")):
        root.remove(child)
    extension = ET.SubElement(root, "mujoco")
    ET.SubElement(extension, "compiler", meshdir=".", balanceinertia="true",
                  discardvisual="false", fusestatic="false", strippath="false")
    temporary = folder / "_g1_compiler.urdf"
    ET.ElementTree(root).write(temporary, encoding="unicode")
    model = mujoco.MjModel.from_xml_path(str(temporary))
    robot_path = folder / "g1_29dof.xml"
    mujoco.mj_saveLastXML(str(robot_path), model)
    temporary.unlink()
    robot = ET.parse(robot_path).getroot()
    pelvis = robot.find(".//body[@name='pelvis']")
    if pelvis is None:
        raise ValueError("compiled URDF lacks pelvis")
    ET.SubElement(pelvis, "freejoint", name="floating_base_joint")
    ET.ElementTree(robot).write(robot_path, encoding="unicode")

    option = robot.find("option")
    if option is None:
        option = ET.SubElement(robot, "option")
    option.set("timestep", "0.005")
    option.set("integrator", "implicitfast")
    option.set("cone", "pyramidal")
    world = robot.find("worldbody")
    ET.SubElement(world, "geom", name="floor", type="plane", size="0 0 0.05",
                  friction="1 0.005 0.0001", rgba="0.25 0.28 0.3 1", contype="1", conaffinity="2")
    for geom in pelvis.iter("geom"):
        # Visual geoms already use zero contact bits. Preserve them.
        if geom.get("contype", "1") == "0" and geom.get("conaffinity", "1") == "0":
            continue
        geom.set("contype", "2")
        geom.set("conaffinity", "3" if self_collisions else "1")
        geom.set("friction", "1 0.005 0.0001")
    actuators = ET.SubElement(robot, "actuator")
    for name in G1_JOINT_NAMES:
        effort, _, armature = motor_of(name)
        joint = robot.find(f".//joint[@name='{name}']")
        if joint is None:
            raise ValueError(f"robot joint missing: {name}")
        joint.set("armature", str(armature))
        joint.set("damping", "0")
        joint.set("frictionloss", "0")
        ET.SubElement(actuators, "position", name=name.removesuffix("_joint"), joint=name,
                      kp=str(_kp(armature)), kv=str(_kd(armature)),
                      forcelimited="true", forcerange=f"{-effort} {effort}", ctrllimited="false")
    scene_path = folder / ("scene.xml" if self_collisions else "scene-no-self-collision.xml")
    ET.ElementTree(robot).write(scene_path, encoding="unicode")
    compiled = mujoco.MjModel.from_xml_path(str(scene_path))
    if (compiled.nq, compiled.nv, compiled.nu) != (36, 35, 29):
        raise ValueError("compiled robot dimensions differ from G1")
    if [compiled.actuator(i).name for i in range(29)] != [n.removesuffix("_joint") for n in G1_JOINT_NAMES]:
        raise ValueError("compiled actuator order differs from CSV order")
    receipt = {"format": "moonrobo.aligned-robot-compilation.v1",
               "urdf_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
               "robot_path": str(robot_path), "scene_path": str(scene_path),
               "robot_sha256": hashlib.sha256(robot_path.read_bytes()).hexdigest(),
               "scene_sha256": hashlib.sha256(scene_path.read_bytes()).hexdigest(),
               "mujoco_version": mujoco.__version__, "self_collisions": self_collisions,
               "dimensions": {"qpos": compiled.nq, "qvel": compiled.nv, "actions": compiled.nu},
               "substep_seconds": compiled.opt.timestep,
               "actuator_names": [compiled.actuator(i).name for i in range(29)],
               "physics_scope": "native MuJoCo; matching retarget URDF and PD constants, not Isaac/MuJoCo-Warp parity"}
    (folder / "compilation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def convert_usd(mjcf_path, output_directory):
    """Offline asset conversion in the pinned Isaac environment, before simulation.

    Adapted from smc/tools/mjcf_to_usd.py; imports are deliberately optional.
    """
    from pxr import Plug
    import isaacsim.asset.importer.utils.impl as importer_utils
    Plug.Registry().RegisterPlugins(str(Path(importer_utils.__file__).parent/'schemas'))
    from isaacsim.asset.importer.mjcf import MJCFImporter, MJCFImporterConfig
    return MJCFImporter(MJCFImporterConfig(mjcf_path=str(Path(mjcf_path).resolve()),
                         usd_path=str(Path(output_directory).resolve()))).import_mjcf()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--description")
    parser.add_argument("--mjcf", help="already compiled robot MJCF for optional USD conversion")
    parser.add_argument("--usd-output", help="offline USD destination; requires pinned Isaac importer")
    parser.add_argument("--disable-self-collisions", action="store_true")
    args = parser.parse_args()
    if args.usd_output:
        if not args.mjcf:
            parser.error('--usd-output requires --mjcf')
        print(convert_usd(args.mjcf, args.usd_output))
    else:
        if not args.description:
            parser.error('--description is required for native compilation')
        print(json.dumps(compile_description(args.description, self_collisions=not args.disable_self_collisions), indent=2))
