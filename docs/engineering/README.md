# Vectie T1 engineering proposal

Revision V0 · 2026-10-29 · **Proposal, not a released hardware design**

Vectie T1 is our proposed humanoid platform. It first walks reliably, then performs
stationary manipulation, then completes supervised mobile manipulation tasks.
The first complete task is: identify an object, walk to its station, stabilize,
grasp, carry, place, and return to standby. Failed grasps and operator interruption
are part of the task, not exceptions hidden from evaluation.

Product name: **Vectie T1**. Brand: **Vectie**. Model: **T1**.
Use `vectie-t1` as the canonical model identifier in future robot packages;
hardware revisions and per-unit serial numbers remain separate fields.
**MoonRobo** is the robot software platform. **V0** identifies this specification
revision, not the product name or a released hardware revision.

The proposed body has **28 joints plus two independently controlled grippers**:
12 leg, two waist and 14 arm joints. RP1 supplies the most relevant open hardware
reference; E1 supplies useful integration and simulation references; G1 supplies
the motion benchmark. SuperMimic and MoonRobo provide the learning and evidence
path. GO-1 is a separate manipulation research candidate whose complete RK3588
deployment remains to be established.

| Document | What it answers |
| --- | --- |
| [Engineering specification](SPECIFICATION_V0.md) | What to build, interfaces, proposed performance targets and acceptance tests |
| [Repository and resource audit](RESOURCE_AUDIT.md) | What was inspected, what can be reused, current incompatibilities, external resources and licenses |
| [Development and resource plan](DEVELOPMENT_PLAN.md) | People, equipment, procurement packages, stages, risks and immediate work |

## Decisions proposed for the first design review

1. Adopt the 28-joint body with simple grippers and a fixed sensor mount.
2. Use purchased actuator modules and an RP1-informed mechanical design;
   qualify our own mass properties, motor maps, wiring and calibration.
3. Target an indoor, supervised robot of 1.30–1.40 m and at most 40 kg, including
   battery and compute. These are design targets requiring a closed mass budget.
4. Demonstrate walking before manipulation, and stationary manipulation before
   carrying. Keep a conventional locomotion baseline alongside SuperMimic.
5. Establish a complete GPU manipulation reference before making RK3588 the
   deployment requirement. Select compute from measured latency, memory and heat.
6. Use owned or explicitly licensed production data and model weights. Research
   access and code licenses do not establish product distribution rights.

## Evidence boundary

The audit covers the named local repositories, selected linked RP1 subprojects,
current primary documentation, and saved MoonRobo experiment artifacts. It is
not an exhaustive review of every source file, CAD assembly, PCB or vendor binary.
No new training, hardware actuation, purchases or supplier messages were performed.
Supplier quotations, physical measurements, complete CAD/BOM reconciliation and
market-specific compliance assessment remain work packages.

Values called **observed** were read in code or saved artifacts. **Reported** values
come from an upstream publisher. **Proposed** values are our engineering targets.
**Open** items must be resolved before the corresponding release gate. Nothing in
these documents implies that a proposed acceptance test has already passed.

The existing [product contract](../PRODUCT_CONTRACT.md) remains authoritative:
MoonRobo governs robot access, safety and evidence; it does not acquire general
agent authority or permission for unattended physical operation through this
proposal. The specification describes a future system assembled around that boundary.
