///|
/// Pure host orchestration, with no interpreter, SDK or GPU interaction.
pub suberror ScheduleError {
  Invalid(String)
  MissingBackend(String)
} derive(Debug)

///|
/// These facts must be observed from the actual initialized pinned manager.
/// Callback cardinality preserves every callback in its original list order.
pub(all) struct ManagerFacts {
  num_envs : Int32
  num_substeps : Int32
  solver_dt : Double
  physics_dt : Double
  decimation : Int32
  single_state : Bool
  use_mujoco_contacts : Bool
  staged_body_forces : Bool
  pre_actuator_callbacks : Int32
  has_adapter : Bool
  post_actuator_callbacks : Int32
  state_force_callbacks : Int32
  post_step_callbacks : Int32
  imu_sensors : Int32
  report_contacts : Bool
  contact_sensors : Int32
  particle_forces : Bool
} derive(Debug)

///|
pub(all) enum ResetField {
  RootLinkPose
  RootComVelocity
  JointPosition
  JointVelocity
} derive(Debug, Eq)

///|
/// A solver call remains a required operation, never a placeholder C ABI or
/// an empty graph. Step is the complete upstream SolverMuJoCo.step call.
pub(all) enum SolverCall {
  Step(dt~ : Double)
  ResetWarmStart(flags~ : Int32)
  NotifyModelChanged
} derive(Debug)

///|
/// ForwardBoundary is the complete guarded manager.forward operation:
/// reset solver internals, masked Newton FK, clear FK/world masks, mark clean.
/// Its implementation must preserve the dirty/external-replay guard. Publish
/// includes scene.update(dt), explicit user-order refresh and four real reads.
pub(all) enum Op {
  SetPositionTarget(reset~ : Bool)
  WriteSceneData
  StageBodyForces
  PreActuatorCallback(Int32)
  AdapterStep(dt~ : Double, swap_state~ : Bool)
  PostActuatorCallback(Int32)
  RestoreBodyForces(substep~ : Int32)
  StateForceCallback(substep~ : Int32, index~ : Int32)
  Solver(SolverCall)
  ClearStateForces(substep~ : Int32, particles~ : Bool)
  PostStepCallback(Int32)
  ImuSensor(Int32)
  UpdateContacts
  ContactSensor(Int32)
  WriteReset(ResetField)
  ForwardBoundary
  Publish(dt~ : Double)
} derive(Debug)

///|
/// Every node depends on its predecessor. No lowering may reorder force
/// restore, actuator submission, warm-start clearing, publication or solver work.
pub(all) struct Node {
  id : Int32
  depends_on : Array[Int32]
  operation : Op
} derive(Debug)

///|
/// Construction is private; accessors return copies of mutable arrays.
pub struct Schedule {
  roles : Map[String, Array[Node]]
  worlds : Int32
}

///|
pub fn Schedule::operations(
  self : Schedule,
  role : @contracts.GraphRole,
) -> Array[Node] {
  self.roles
  .get(role.name())
  .unwrap()
  .map(fn(node) { { ..node, depends_on: node.depends_on.copy(), } })
}

///|
pub fn Schedule::num_envs(self : Schedule) -> Int32 {
  self.worlds
}

///|
fn push(nodes : Array[Node], operation : Op) -> Unit {
  let id = nodes.length()
  nodes.push({ id, depends_on: if id == 0 { [] } else { [id - 1] }, operation, })
}

///|
/// Compile only the exact pinned G1 CUDA manager configuration. A schedule
/// is a source plan; creation does not attest backend availability or execution.
pub fn compile(facts : ManagerFacts) -> Schedule raise ScheduleError {
  guard facts.num_envs > 0 &&
    facts.num_envs <= 1000000 &&
    facts.num_substeps == 4 &&
    facts.solver_dt == 0.005 &&
    facts.physics_dt == 0.02 &&
    facts.decimation == 1 &&
    facts.single_state &&
    facts.use_mujoco_contacts else {
    raise Invalid(
      "schedule requires fixed G1 single-state internal-contact four-substep configuration",
    )
  }
  for
    count in [
      facts.pre_actuator_callbacks,
      facts.post_actuator_callbacks,
      facts.state_force_callbacks,
      facts.post_step_callbacks,
      facts.imu_sensors,
      facts.contact_sensors,
    ] {
    guard count >= 0 && count <= 1000000 else {
      raise Invalid("invalid observed callback/sensor cardinality")
    }
  }
  guard facts.report_contacts || facts.contact_sensors == 0 else {
    raise Invalid("contact sensors exist while contact reporting is disabled")
  }
  let step : Array[Node] = []
  push(step, SetPositionTarget(reset=false))
  push(step, WriteSceneData)
  if facts.staged_body_forces {
    push(step, StageBodyForces)
  }
  for i in 0..<facts.pre_actuator_callbacks {
    push(step, PreActuatorCallback(i))
  }
  if facts.has_adapter {
    push(step, AdapterStep(dt=0.02, swap_state=false))
  }
  for i in 0..<facts.post_actuator_callbacks {
    push(step, PostActuatorCallback(i))
  }
  for substep in 0..<4 {
    if facts.staged_body_forces {
      push(step, RestoreBodyForces(substep~))
    }
    for index in 0..<facts.state_force_callbacks {
      push(step, StateForceCallback(substep~, index~))
    }
    push(step, Solver(Step(dt=0.005)))
    push(step, ClearStateForces(substep~, particles=facts.particle_forces))
  }
  for i in 0..<facts.post_step_callbacks {
    push(step, PostStepCallback(i))
  }
  for i in 0..<facts.imu_sensors {
    push(step, ImuSensor(i))
  }
  if facts.report_contacts {
    push(step, UpdateContacts)
    for i in 0..<facts.contact_sensors {
      push(step, ContactSensor(i))
    }
  }
  push(step, Publish(dt=0.02))
  let reset : Array[Node] = []
  for field in [RootLinkPose, RootComVelocity, JointPosition, JointVelocity] {
    push(reset, WriteReset(field))
  }
  push(reset, SetPositionTarget(reset=true))
  push(reset, Solver(ResetWarmStart(flags=0)))
  push(reset, ForwardBoundary)
  push(reset, Publish(dt=0.0))
  let context : Array[Node] = []
  push(context, Solver(NotifyModelChanged))
  push(context, ForwardBoundary)
  push(context, Publish(dt=0.0))
  let refresh : Array[Node] = []
  push(refresh, ForwardBoundary)
  push(refresh, Publish(dt=0.0))
  {
    roles: Map([
      ("step", step),
      ("reset", reset),
      ("context", context),
      ("refresh", refresh),
    ]),
    worlds: facts.num_envs,
  }
}

///|
/// Stable identifiers for coverage checks and implementation dispatch.
pub fn Op::key(self : Op) -> String {
  match self {
    SetPositionTarget(reset=false) => "articulation.target"
    SetPositionTarget(reset=true) => "articulation.reset_target"
    WriteSceneData => "scene.write_data"
    StageBodyForces => "manager.stage_body_forces"
    PreActuatorCallback(i) => "manager.pre_actuator.\{i}"
    AdapterStep(..) => "actuators.adapter_step"
    PostActuatorCallback(i) => "manager.post_actuator.\{i}"
    RestoreBodyForces(..) => "manager.restore_body_forces"
    StateForceCallback(index=i, ..) => "manager.state_force.\{i}"
    Solver(Step(..)) => "solver.step"
    Solver(ResetWarmStart(..)) => "solver.reset_warm_start"
    Solver(NotifyModelChanged) => "solver.notify_model_changed"
    ClearStateForces(..) => "state.clear_forces"
    PostStepCallback(i) => "manager.post_step.\{i}"
    ImuSensor(i) => "sensor.imu.\{i}"
    UpdateContacts => "solver.update_contacts"
    ContactSensor(i) => "sensor.contact.\{i}"
    WriteReset(RootLinkPose) => "articulation.reset_root_pose"
    WriteReset(RootComVelocity) => "articulation.reset_root_velocity"
    WriteReset(JointPosition) => "articulation.reset_joint_position"
    WriteReset(JointVelocity) => "articulation.reset_joint_velocity"
    ForwardBoundary => "manager.forward"
    Publish(..) => "scene.publish"
  }
}
