// Derived from pinned Newton usd/schema_resolver.py and usd/schemas.py.
// SPDX-FileCopyrightText: Copyright (c) 2025 The Newton Developers
// SPDX-License-Identifier: Apache-2.0

///|
priv struct Binding {
  attribute : String
  fallback : Json
  transform : String
  kind : String
}

///|
fn binding(
  attribute : String,
  fallback : Json,
  kind~ : String = "number",
  transform~ : String = "identity",
) -> Binding {
  { attribute, fallback, transform, kind, }
}

///|
/// Finite, explicit subset of the three pinned builtin maps. Unknown logical
/// keys fail instead of pretending to implement the full vendor schema.
fn mapping(resolver : String, prim : String, key : String) -> Binding? {
  match (resolver, prim, key) {
    ("newton", "scene", "max_solver_iterations") =>
      Some(binding("newton:maxSolverIterations", Json(-1)))
    ("newton", "scene", "time_steps_per_second") =>
      Some(binding("newton:timeStepsPerSecond", Json(1000)))
    ("newton", "scene", "gravity_enabled") =>
      Some(binding("newton:gravityEnabled", Json(true), kind="bool"))
    ("newton", "joint", "armature") =>
      Some(binding("newton:armature", Json(0.0)))
    ("newton", "joint", "damping") =>
      Some(binding("newton:damping", Json(null)))
    ("newton", "joint", "friction") =>
      Some(binding("newton:friction", Json(0.0)))
    ("newton", "joint", "limit_ke") =>
      Some(binding("newton:limitStiffness", Json(null)))
    ("newton", "joint", "limit_kd") =>
      Some(binding("newton:limitDamping", Json(null)))
    ("newton", "joint", "velocity_limit") =>
      Some(binding("newton:velocityLimit", Json("+inf")))
    ("newton", "shape", "max_hull_vertices") =>
      Some(binding("newton:maxHullVertices", Json(-1)))
    ("newton", "shape", "margin") =>
      Some(binding("newton:contactMargin", Json(0.0)))
    ("newton", "shape", "gap") =>
      Some(binding("newton:contactGap", Json("-inf")))
    ("newton", "shape", "mass_model") =>
      Some(binding("newton:massModel", Json("solid"), kind="text"))
    ("newton", "shape", "shell_thickness") =>
      Some(binding("newton:shellThickness", Json("-inf")))
    ("newton", "shape", "ke") => Some(binding("newton:contact_ke", Json(null)))
    ("newton", "shape", "kd") => Some(binding("newton:contact_kd", Json(null)))
    ("newton", "shape", "kf") => Some(binding("newton:contact_kf", Json(null)))
    ("newton", "shape", "ka") => Some(binding("newton:contact_ka", Json(null)))
    ("newton", "material", "mu_torsional") =>
      Some(binding("newton:torsionalFriction", Json(0.005)))
    ("newton", "material", "mu_rolling") =>
      Some(binding("newton:rollingFriction", Json(0.0001)))
    ("newton", "material", "ke") =>
      Some(binding("newton:contactStiffness", Json(null)))
    ("newton", "material", "kd") =>
      Some(binding("newton:contactDamping", Json(null)))
    ("newton", "material", "kf") =>
      Some(binding("newton:contactFrictionGain", Json(null)))
    ("newton", "material", "ka") =>
      Some(binding("newton:contactAdhesion", Json(null)))
    ("newton", "articulation", "self_collision_enabled") =>
      Some(binding("newton:selfCollisionEnabled", Json(true), kind="bool"))
    ("physx", "scene", "max_solver_iterations") =>
      Some(binding("physxScene:maxVelocityIterationCount", Json(255)))
    ("physx", "scene", "time_steps_per_second") =>
      Some(binding("physxScene:timeStepsPerSecond", Json(60)))
    ("physx", "scene", "gravity_enabled") =>
      Some(
        binding(
          "physxRigidBody:disableGravity",
          Json(false),
          kind="bool",
          transform="not",
        ),
      )
    ("physx", "joint", "armature") =>
      Some(binding("physxJoint:armature", Json(0.0)))
    ("physx", "joint", "velocity_limit") =>
      Some(binding("physxJoint:maxJointVelocity", Json(null)))
    ("physx", "shape", "max_hull_vertices") =>
      Some(binding("physxConvexHullCollision:hullVertexLimit", Json(64)))
    ("physx", "shape", "margin") =>
      Some(
        binding(
          "physxCollision:restOffset",
          Json(0.0),
          transform="physx-margin",
        ),
      )
    ("physx", "shape", "gap") =>
      Some(
        binding(
          "physxCollision:contactOffset",
          Json("-inf"),
          transform="physx-gap",
        ),
      )
    ("physx", "material", "ke") =>
      Some(binding("physxMaterial:compliantContactStiffness", Json(null)))
    ("physx", "material", "kd") =>
      Some(binding("physxMaterial:compliantContactDamping", Json(null)))
    ("physx", "body", "rigid_body_linear_damping") =>
      Some(binding("physxRigidBody:linearDamping", Json(0.0)))
    ("physx", "body", "rigid_body_angular_damping") =>
      Some(binding("physxRigidBody:angularDamping", Json(0.05)))
    ("physx", "articulation", "self_collision_enabled") =>
      Some(
        binding(
          "physxArticulation:enabledSelfCollisions",
          Json(true),
          kind="bool",
        ),
      )
    ("mjc", "scene", "max_solver_iterations") =>
      Some(binding("mjc:option:iterations", Json(100)))
    ("mjc", "scene", "time_steps_per_second") =>
      Some(
        binding("mjc:option:timestep", Json(0.002), transform="reciprocal-int"),
      )
    ("mjc", "scene", "gravity_enabled") =>
      Some(binding("mjc:flag:gravity", Json(true), kind="bool"))
    ("mjc", "joint", "armature") => Some(binding("mjc:armature", Json(0.0)))
    ("mjc", "joint", "damping_per_rad") =>
      Some(binding("mjc:damping", Json(null)))
    ("mjc", "joint", "friction") => Some(binding("mjc:frictionloss", Json(0.0)))
    ("mjc", "joint", "effort_limit") =>
      Some(binding("mjc:actuatorfrcrange:min", Json(null), transform="effort"))
    ("mjc", "shape", "max_hull_vertices") =>
      Some(binding("mjc:maxhullvert", Json(-1)))
    ("mjc", "shape", "margin") => Some(binding("mjc:margin", Json(0.0)))
    ("mjc", "shape", "gap") => Some(binding("mjc:gap", Json(0.0)))
    ("mjc", "shape", "mass_model") =>
      Some(
        binding("mjc:shellinertia", Json(false), kind="bool", transform="shell"),
      )
    ("mjc", "shape" | "material", "ke") =>
      Some(binding("mjc:solref", Json(null), transform="solref-k"))
    ("mjc", "shape" | "material", "kd") =>
      Some(binding("mjc:solref", Json(null), transform="solref-d"))
    ("mjc", "material", "mu_torsional") =>
      Some(binding("mjc:torsionalfriction", Json(0.005)))
    ("mjc", "material", "mu_rolling") =>
      Some(binding("mjc:rollingfriction", Json(0.0001)))
    ("mjc", "material", "priority") => Some(binding("mjc:priority", Json(0)))
    ("mjc", "material", "weight") => Some(binding("mjc:solmix", Json(1.0)))
    _ => None
  }
}

///|
fn number(value : Json) -> Double raise {
  let result : Double = @json.from_json(value)
  guard finite(result) else {
    fail("nonfinite numeric USD value must use an explicit sentinel")
  }
  result
}

///|
fn convert(
  spec : Binding,
  value : Json,
  attrs : Map[String, Json],
  authored : Bool,
) -> Json raise {
  if value == Json(null) {
    return Json(null)
  }
  match spec.transform {
    "physx-gap" if authored => {
      let rest = attrs.get("physxCollision:restOffset").unwrap_or(Json(null))
      if rest == Json(null) || rest == Json("-inf") || value == Json("-inf") {
        Json(null)
      } else {
        let result = number(value) - number(rest)
        guard finite(result) else { fail("PhysX gap overflows") }
        Json(result)
      }
    }
    "physx-gap" => value // Mapping default has no transformer, unlike its getter.
    "physx-margin" if value == Json("-inf") => Json(null)
    "not" => {
      let v : Bool = @json.from_json(value)
      Json(!v)
    }
    "shell" => {
      let v : Bool = @json.from_json(value)
      Json(if v { "shell" } else { "solid" })
    }
    "reciprocal-int" => {
      let v = number(value)
      if v <= 0.0 {
        Json(null)
      } else {
        let rate = 1.0 / v
        guard finite(rate) && rate <= 2147483647.0 else {
          fail("timestep frequency exceeds supported int32")
        }
        Json(rate.to_int())
      }
    }
    "solref-k" | "solref-d" => {
      let values : Array[Double] = @json.from_json(value)
      guard values.length() == 2 && values.all(finite) else {
        fail("supported solref requires two finite values")
      }
      let t = values[0]
      let d = values[1]
      if t < 0.0 && d < 0.0 {
        Json(if spec.transform == "solref-k" { -t } else { -d })
      } else if t <= 0.0 || d <= 0.0 {
        Json(null)
      } else {
        let out = if spec.transform == "solref-k" {
          1.0 / (t * t * d * d)
        } else {
          2.0 / t
        }
        guard finite(out) else { fail("supported solref conversion overflows") }
        Json(out)
      }
    }
    "effort" if authored => {
      let low = attrs.get("mjc:actuatorfrcrange:min").unwrap_or(Json(null))
      let high = attrs.get("mjc:actuatorfrcrange:max").unwrap_or(Json(null))
      if low == Json(null) && high == Json(null) {
        Json(null)
      } else {
        let lo = if low == Json(null) { 0.0 } else { number(low) }
        let hi = if high == Json(null) { 0.0 } else { number(high) }
        let limited = attrs
          .get("mjc:actuatorfrclimited")
          .unwrap_or(Json("auto"))
        guard limited == Json("auto") ||
          limited == Json("true") ||
          limited == Json("false") else {
          fail("unsupported actuatorfrclimited token")
        }
        if limited == Json("true") || (limited == Json("auto") && lo < hi) {
          Json(math_max(lo.abs(), hi.abs()))
        } else {
          Json(null)
        }
      }
    }
    _ =>
      match spec.kind {
        "bool" => {
          let v : Bool = @json.from_json(value)
          Json(v)
        }
        "text" => {
          let v : String = @json.from_json(value)
          Json(v)
        }
        _ =>
          if value == Json("+inf") || value == Json("-inf") {
            value
          } else {
            Json(number(value))
          }
      }
  }
}

///|
fn math_max(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
/// First authored transformed value, explicit default, then first mapping
/// default; defaults never report an authored supplying resolver.
pub fn resolve_schema(request : SchemaRequest) -> Json raise {
  guard request.resolvers.length() <= 3 &&
    request.keys.length() <= 256 &&
    request.attributes.length() <= 4096 &&
    ["scene", "joint", "shape", "body", "material", "actuator", "articulation"].contains(
      request.prim_type,
    ) else {
    fail("unsupported schema request scope")
  }
  let seen : Map[String, Unit] = Map([])
  for resolver in request.resolvers {
    guard ["newton", "mjc", "physx"].contains(resolver) &&
      !seen.contains(resolver) else {
      fail("unknown or duplicate builtin resolver")
    }
    seen[resolver] = ()
  }
  let resolved : Map[String, Json] = Map([])
  let collected : Map[String, Json] = Map([])
  for key in request.keys {
    guard !resolved.contains(key) &&
      ["newton", "mjc", "physx"].any(r => {
        mapping(r, request.prim_type, key) is Some(_)
      }) else {
      fail(
        "unknown/duplicate logical key outside supported schema maps: " + key,
      )
    }
    let mut value : Json = Json(null)
    let mut origin = "missing"
    let mut supplier : Json = Json(null)
    for resolver in request.resolvers {
      if mapping(resolver, request.prim_type, key) is Some(spec) {
        let raw = if spec.transform == "effort" {
          // Getter can succeed when only the upper range attribute is authored.
          if request.attributes.get(spec.attribute).unwrap_or(Json(null)) !=
            Json(null) {
            request.attributes[spec.attribute]
          } else {
            request.attributes
            .get("mjc:actuatorfrcrange:max")
            .unwrap_or(Json(null))
          }
        } else {
          request.attributes.get(spec.attribute).unwrap_or(Json(null))
        }
        let candidate = convert(spec, raw, request.attributes, true)
        if candidate != Json(null) {
          value = candidate
          origin = "authored"
          supplier = Json(resolver)
          // Collect on first successful use, once per resolver/prim. Preserve
          // explicit namespaced null values, as time-sampled missing defaults.
          if !collected.contains(resolver) {
            let attrs : Map[String, Json] = Map([])
            for name, v in request.attributes {
              if name.has_prefix(resolver + ":") ||
                (
                  resolver == "physx" &&
                  [
                    "physxScene:", "physxRigidBody:", "physxCollision:", "physxConvexHullCollision:",
                    "physxConvexDecompositionCollision:", "physxTriangleMeshCollision:",
                    "physxTriangleMeshSimplificationCollision:", "physxSDFMeshCollision:",
                    "physxMaterial:", "physxJoint:", "physxLimit:", "physxArticulation:",
                    "state:", "drive:",
                  ].any(p => name.has_prefix(p))
                ) {
                attrs[name] = v
              }
            }
            collected[resolver] = Json(attrs)
          }
          break
        }
      }
    }
    if origin == "missing" {
      let fallback = request.defaults.get(key).unwrap_or(Json(null))
      if fallback != Json(null) {
        value = fallback
        origin = "caller-default"
      } else {
        for resolver in request.resolvers {
          if mapping(resolver, request.prim_type, key) is Some(spec) &&
            spec.fallback != Json(null) {
            value = convert(spec, spec.fallback, request.attributes, false)
            origin = "mapping-default"
            break
          }
        }
      }
    }
    resolved[key] = {
      "value": value,
      "origin": Json(origin),
      "authored_resolver": supplier,
    }
  }
  for key in request.defaults.keys() {
    guard request.keys.contains(key) else {
      fail("caller default for unqueried schema key")
    }
  }
  {
    "format": "moonrobo-authored-schema-resolution-v1",
    "values": Json(resolved),
    "collected_on_first_use": Json(collected),
    "numeric_backend": "CPU/Double",
    "nonfinite_encoding": "explicit strings +inf/-inf",
    "full_usd_import": false,
    "custom_resolvers_supported": false,
    "runtime_equivalence_verified": false,
  }
}
