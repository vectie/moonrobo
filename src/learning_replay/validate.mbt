///|
fn finite_vector(
  values : Array[Double],
  width : Int32,
  field : String,
) -> Unit raise {
  guard values.length() == width && values.all(x => !x.is_nan() && !x.is_inf()) else {
    fail("invalid replay " + field)
  }
}

///|
fn quaternion(values : Array[Double], field : String) -> Unit raise {
  finite_vector(values, 4, field)
  let norm = values.fold(init=0.0, (sum, x) => sum + x * x)
  guard (norm - 1.0).abs() <= 0.00001 else {
    fail("replay quaternion must have unit length: " + field)
  }
}

///|
pub fn valid_sha256(value : String) -> Bool {
  value.length() == 64 &&
  value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

///|
/// Portable mesh names are relative, with no URLs, traversal or escape syntax.
pub fn safe_asset_path(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 240 &&
  value
  .iter()
  .all(c => {
    (c >= 'a' && c <= 'z') ||
    (c >= 'A' && c <= 'Z') ||
    (c >= '0' && c <= '9') ||
    c == '_' ||
    c == '-' ||
    c == '.' ||
    c == '/'
  }) &&
  value.split("/").all(part => part != "" && part != "." && part != "..")
}

///|
fn number(value : Json, field : String) -> Double raise {
  guard value is Number(x, ..) && !x.is_nan() && !x.is_inf() else {
    fail("invalid replay numeric field: " + field)
  }
  x
}

///|
fn geometry_vector(
  value : Json,
  width : Int32,
  field : String,
  positive : Bool,
) -> Unit raise {
  guard value is Array(items) && items.length() == width else {
    fail("invalid replay geometry vector: " + field)
  }
  for item in items {
    let x = number(item, field)
    guard (if positive { x > 0.0 } else { x >= 0.0 }) else {
      fail("invalid replay geometry extent: " + field)
    }
  }
}

///|
fn validate_geometry(geometry : Json) -> Unit raise {
  match geometry {
    { "kind": "mesh", "asset": String(asset), "sha256": String(hash), .. } => {
      guard safe_asset_path(asset) &&
        valid_sha256(hash) &&
        (asset == hash + ".obj" || asset == hash + ".stl") else {
        fail("invalid replay mesh asset or SHA256")
      }
      if geometry is { "scale": scale, .. } {
        geometry_vector(scale, 3, "mesh.scale", true)
      }
    }
    { "kind": "box", "size": size, .. } =>
      geometry_vector(size, 3, "box.size", true)
    { "kind": "sphere", "radius": radius, .. } => {
      guard number(radius, "sphere.radius") > 0 else {
        fail("invalid sphere radius")
      }
    }
    { "kind": "capsule", "radius": radius, "length": length, .. } => {
      guard number(radius, "radius") > 0 && number(length, "length") >= 0 else {
        fail("invalid capsule")
      }
    }
    { "kind": "cylinder", "radius": radius, "length": length, .. } => {
      guard number(radius, "radius") > 0 && number(length, "length") > 0 else {
        fail("invalid cylinder")
      }
    }
    { "kind": "ellipsoid", "radii": radii, .. } =>
      geometry_vector(radii, 3, "ellipsoid.radii", true)
    { "kind": "plane", "size": size, .. } =>
      geometry_vector(size, 2, "plane.size", false)
    _ => fail("unsupported replay geometry")
  }
}

///|
pub fn Model::validate(self : Model) -> Unit raise {
  guard !self.id.is_empty() &&
    valid_sha256(self.sha256) &&
    self.coordinate_system == "right-handed-z-up" &&
    !self.bodies.is_empty() &&
    self.bodies.length() <= 512 &&
    !self.visuals.is_empty() &&
    self.visuals.length() <= 2048 else {
    fail("invalid replay model identity, coordinate system or geometry count")
  }
  let ids : Map[String, Unit] = Map([])
  for body in self.bodies {
    guard !body.id.is_empty() && !ids.contains(body.id) else {
      fail("duplicate or empty replay body ID")
    }
    // Parent-before-child order also excludes cycles without recursive traversal.
    if body.parent_id is Some(parent) {
      guard ids.contains(parent) else {
        fail("replay body parent missing or unordered")
      }
    }
    ids[body.id] = ()
  }
  let visuals : Map[String, Unit] = Map([])
  for visual in self.visuals {
    guard !visual.id.is_empty() &&
      !visuals.contains(visual.id) &&
      ids.contains(visual.body_id) else {
      fail("invalid replay visual binding")
    }
    visuals[visual.id] = ()
    finite_vector(visual.local_position, 3, "visual.local_position")
    quaternion(visual.local_quaternion_wxyz, "visual.local_quaternion_wxyz")
    finite_vector(visual.rgba, 4, "visual.rgba")
    guard visual.rgba.all(x => x >= 0 && x <= 1) else {
      fail("invalid replay rgba")
    }
    validate_geometry(visual.geometry)
  }
}

///|
/// Frame validation is reusable for a future live channel. A frame is complete;
/// missing bodies must never inherit stale transforms from a previous frame.
pub fn PoseFrame::validate(self : PoseFrame, model : Model) -> Unit raise {
  guard !self.time_s.is_nan() &&
    !self.time_s.is_inf() &&
    self.time_s >= 0 &&
    self.bodies.length() == model.bodies.length() else {
    fail("invalid replay frame time or incomplete body poses")
  }
  let expected : Map[String, Unit] = Map([])
  for body in model.bodies {
    expected[body.id] = ()
  }
  for pose in self.bodies {
    guard expected.contains(pose.body_id) else {
      fail("duplicate or unknown pose body")
    }
    expected.remove(pose.body_id)
    finite_vector(pose.position, 3, "position")
    quaternion(pose.quaternion_wxyz, "quaternion_wxyz")
  }
}

///|
pub fn PoseReplay::validate(self : PoseReplay) -> Unit raise {
  guard self.format == "moonrobo.pose-replay.v1" &&
    !self.clips.is_empty() &&
    self.clips.length() <= 256 else {
    fail("invalid pose replay format or clips")
  }
  self.model.validate()
  let clip_ids : Map[String, Unit] = Map([])
  let mut total_poses = 0
  let mut total_frames = 0
  for clip in self.clips {
    guard !clip.id.is_empty() &&
      !clip_ids.contains(clip.id) &&
      !clip.source_start_time_s.is_nan() &&
      !clip.source_start_time_s.is_inf() &&
      clip.source_start_time_s >= 0 &&
      !clip.tracks.is_empty() &&
      clip.tracks.length() <= 8 else {
      fail("invalid replay clip")
    }
    clip_ids[clip.id] = ()
    let track_ids : Map[String, Unit] = Map([])
    for track in clip.tracks {
      guard !track.id.is_empty() &&
        !track_ids.contains(track.id) &&
        (track.kind == "physics" || track.kind == "reference") &&
        !track.frames.is_empty() &&
        track.frames.length() <= 100000 else {
        fail("invalid replay track")
      }
      track_ids[track.id] = ()
      let mut previous = -1.0
      for frame in track.frames {
        guard frame.time_s > previous else {
          fail("replay timestamps must strictly increase")
        }
        frame.validate(self.model)
        previous = frame.time_s
        total_poses += frame.bodies.length()
        total_frames += 1
        guard total_poses <= 2000000 && total_frames <= 200000 else {
          fail("replay frame or pose budget exceeded")
        }
      }
    }
  }
}

///|
pub fn validate_json(value : Json) -> PoseReplay raise {
  let replay : PoseReplay = @json.from_json(value)
  replay.validate()
  replay
}
