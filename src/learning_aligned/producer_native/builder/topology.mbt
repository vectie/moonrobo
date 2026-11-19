///|
priv struct Tree {
  root : Int32
  bodies : Array[Int32]
  joints : Array[Int32]
  body_index : Map[String, Int32]
}

///|
/// Matches the accepted directed-tree branch of pinned Newton topological_sort:
/// DFS children are visited by source joint index. Reversed/merged/loop joints
/// are outside this subset, rather than silently reoriented or merged.
fn tree(source : @scene.ArticulationIR) -> Tree raise {
  let bodies : Map[String, Int32] = {}
  guard source.bodies.length() > 0 && source.bodies.length() <= 10000 else {
    fail("supported builder tree has one to 10000 bodies")
  }
  for index, body in source.bodies {
    guard body.enabled && !body.kinematic && !bodies.contains(body.path) else {
      fail(
        "disabled, kinematic or duplicate body outside supported builder subset",
      )
    }
    ignore(usd_transform(body.world_transform))
    bodies[body.path] = index
  }
  let incoming : Map[String, Int32] = {}
  let outgoing : Map[String, Array[Int32]] = {}
  let paths : Map[String, Unit] = {}
  for index, joint in source.joints {
    guard !paths.contains(joint.path) &&
      joint.enabled &&
      !joint.excluded_from_articulation &&
      (joint.kind == "fixed" || joint.kind == "revolute") &&
      joint.body0.length() == 1 &&
      joint.body1.length() == 1 else {
      fail("unsupported/disabled/excluded/world/duplicate joint")
    }
    paths[joint.path] = ()
    let parent = joint.body0[0]
    let child = joint.body1[0]
    guard bodies.contains(parent) &&
      bodies.contains(child) &&
      parent != child &&
      !incoming.contains(child) else {
      fail("multi-parent, parallel or invalid joint edge")
    }
    incoming[child] = index
    let edges = outgoing.get_or_init(parent, fn() { [] })
    edges.push(index)
  }
  let roots = source.bodies.filter(b => !incoming.contains(b.path))
  guard roots.length() == 1 else {
    fail("builder subset requires one directed floating root")
  }
  let ordered_bodies : Array[Int32] = []
  let ordered_joints : Array[Int32] = []
  let seen : Map[String, Unit] = {}
  let stack = [(roots[0].path, -1)]
  while !stack.is_empty() {
    let (body, edge) = stack.pop().unwrap()
    guard !seen.contains(body) else { fail("cycle in builder joint graph") }
    seen[body] = ()
    ordered_bodies.push(bodies[body])
    if edge >= 0 {
      ordered_joints.push(edge)
    }
    let children = outgoing.get(body).unwrap_or([])
    for i = children.length() - 1; i >= 0; i = i - 1 {
      let joint = children[i]
      stack.push((source.joints[joint].body1[0], joint))
    }
  }
  guard seen.length() == bodies.length() &&
    ordered_joints.length() == source.joints.length() else {
    fail("disconnected graph or hidden cyclic component")
  }
  let body_index : Map[String, Int32] = {}
  for index, source_index in ordered_bodies {
    body_index[source.bodies[source_index].path] = index
  }
  {
    root: bodies[roots[0].path],
    bodies: ordered_bodies,
    joints: ordered_joints,
    body_index,
  }
}
