///|
fn shape_signature(
  output : Map[String, @artifacts.NumericArray],
  name : String,
  layout : Array[(String, Array[Int32])],
) -> Unit {
  let names = layout.map(x => x.0).join("\n")
  output["architecture." + name + ".names"] = array(
    [@utf8.encode(names).length()],
    @utf8.encode(names).to_array().map(b => b.to_int().to_double()),
    dtype="|u1",
  )
  output["architecture." + name] = array(
    [layout.length(), 3],
    flatten(
      layout.map(pair => {
        let shape = pair.1
        [
          shape.length().to_double(),
          shape.get(0).unwrap_or(0).to_double(),
          shape.get(1).unwrap_or(0).to_double(),
        ]
      }),
    ),
    dtype="<i8",
  )
}

///|
fn norm_shapes(prefix : String, n : Int32) -> Array[(String, Array[Int32])] {
  [(prefix + ".mean", [n]), (prefix + ".var", [n]), (prefix + ".count", [])]
}

///|
pub fn candidate_architecture() -> Map[String, @artifacts.NumericArray] {
  let rng = @numeric.Rng::new(912U)
  let wm = @aligned.WorldModel::new(rng)
  let pi = @aligned.Policy::new(99, 730, rng)
  let critic = @aligned.Critic::new(914, rng)
  let output : Map[String, @artifacts.NumericArray] = {}
  let world = slots(wm.net, "net.").map(s => (s.name, s.shape))
  world.append(norm_shapes("in_norm", wm.input_norm.mean.length()))
  world.append(norm_shapes("out_norm", wm.output_norm.mean.length()))
  let policy = slots(pi.encoder, "enc.").map(s => (s.name, s.shape))
  policy.append(slots(pi.decoder, "dec.").map(s => (s.name, s.shape)))
  policy.append(norm_shapes("obs_norm", pi.obs_norm.mean.length()))
  policy.append(norm_shapes("goal_norm", pi.goal_norm.mean.length()))
  let value = slots(critic.net, "net.").map(s => (s.name, s.shape))
  value.append(norm_shapes("norm", critic.norm.mean.length()))
  shape_signature(output, "wm", world)
  shape_signature(output, "pi", policy)
  shape_signature(output, "critic", value)
  output
}

///|
/// Independent Table A.4/upstream constructor metadata, with no tested Network
/// or model constructor invoked by this side of the comparison.
pub fn architecture_mathematical_oracle() -> Map[
  String,
  @artifacts.NumericArray,
] {
  let mlp = (prefix : String, dims : Array[Int32], layer_norm : Bool) => {
    let result = []
    for i in 0..<(dims.length() - 1) {
      let module = i * (if layer_norm { 3 } else { 2 })
      let name = prefix + module.to_string()
      result.push((name + ".weight", [dims[i + 1], dims[i]]))
      result.push((name + ".bias", [dims[i + 1]]))
      if layer_norm && i < dims.length() - 2 {
        let norm = prefix + (module + 1).to_string()
        result.push((norm + ".weight", [dims[i + 1]]))
        result.push((norm + ".bias", [dims[i + 1]]))
      }
    }
    result
  }
  let world = mlp("net.", [133, 2048, 2048, 2048, 70], true)
  world.append(norm_shapes("in_norm", 133))
  world.append(norm_shapes("out_norm", 70))
  let policy = mlp("enc.", [730, 2048, 1024, 512, 256, 32], false)
  policy.append(mlp("dec.", [1022, 2048, 1024, 512, 256, 29], false))
  policy.append(norm_shapes("obs_norm", 99))
  policy.append(norm_shapes("goal_norm", 730))
  let value = mlp("net.", [914, 256, 128, 1], false)
  value.append(norm_shapes("norm", 914))
  let output : Map[String, @artifacts.NumericArray] = {}
  shape_signature(output, "wm", world)
  shape_signature(output, "pi", policy)
  shape_signature(output, "critic", value)
  output
}
