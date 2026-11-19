///|
pub(all) struct CatalogClip {
  id : String
  path : String
  sha256 : String
  layout : String
  fps : Double?
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct MotionCatalog {
  format : String
  quaternion_order : String
  source_fps : Double
  clips : Array[CatalogClip]
  splits : Map[String, Array[String]]
} derive(Debug, ToJson, FromJson)

///|
pub(all) struct LoadedMotion {
  motion : MotionLibrary
  manifest : Json
  manifest_sha256 : String
  split : String
}

///|
fn path_parent(path : String) -> String {
  let parts = path.split("/").to_array()
  let dirs : Array[String] = []
  for i in 0..<(parts.length() - 1) {
    dirs.push(parts[i].to_owned())
  }
  let result = dirs.join("/")
  if result == "" {
    "."
  } else {
    result
  }
}

///|
fn path_stem(path : String) -> String {
  let parts = path.split("/").to_array()
  let name = parts[parts.length() - 1].to_owned()
  if name.has_suffix(".csv") {
    name[:name.length() - 4].to_owned()
  } else {
    name
  }
}

///|
fn require_native_eager_catalog_size(selected_clips : Int32) -> Unit raise {
  // The filtered paper benchmark already contains 129,514 clips; the raw
  // BONES release has 142,220. This is a refusal of these known unsupported
  // full corpora, not a memory-safety claim for every smaller eager catalog.
  guard selected_clips < 129514 else {
    fail(
      "full BONES/paper-scale catalogs require bounded reference storage; native MotionLibrary is eager CPU Float64. Use the preserved providers.motion_learning.aligned.train baseline with --motion-manifest and reference_storage=mmap until native streaming and CUDA training are integrated",
    )
  }
}

///|
pub async fn load_motion_files(
  files : Array[String],
  kin : Kinematics,
  source_fps~ : Double = 30.0,
  compute_body_features~ : Bool = true,
  storage~ : String = "eager",
  cache_dir~ : String = "",
  max_gather_frames~ : Int32 = 131072,
  motion_cache_advice~ : Bool = false,
  cache_advice_report~ : ((MotionCacheAdviceReport) -> Unit)? = None,
) -> MotionLibrary {
  guard ["eager", "mmap"].contains(storage) else {
    fail("unsupported motion storage")
  }
  guard !motion_cache_advice || storage == "mmap" else {
    fail("motion cache advice requires bounded mmap reference storage")
  }
  if storage == "mmap" {
    guard cache_dir != "" else {
      fail("bounded motion storage requires cache_dir")
    }
    let names = files.map(path_stem)
    let seen : Map[String, Bool] = {}
    let hashes : Array[String] = []
    for i, file in files {
      guard !seen.contains(names[i]) else {
        fail("duplicate motion identifiers")
      }
      seen[names[i]] = true
      hashes.push(stream_file_hash(file))
    }
    return load_streamed_motion(
      files, names, hashes, kin, source_fps, cache_dir, compute_body_features, max_gather_frames,
      motion_cache_advice, cache_advice_report,
    )
  }
  require_native_eager_catalog_size(files.length())
  let clips : Array[MotionClip] = []
  for file in files {
    let bytes = @fs.read_file(file).binary()
    clips.push({
      name: path_stem(file),
      sha256: @artifacts.sha256(bytes),
      rows: parse_motion_csv(@utf8.decode(bytes)),
    })
  }
  MotionLibrary::new(clips, kin, source_fps~, compute_body_features~)
}

///|
pub async fn load_motion_directory(
  directory : String,
  kin : Kinematics,
  source_fps~ : Double = 30.0,
  compute_body_features~ : Bool = true,
  storage~ : String = "eager",
  cache_dir~ : String = "",
  max_gather_frames~ : Int32 = 131072,
  motion_cache_advice~ : Bool = false,
  cache_advice_report~ : ((MotionCacheAdviceReport) -> Unit)? = None,
) -> LoadedMotion {
  let names = @fs.readdir(directory, sort=true).filter(name => {
    name.has_suffix(".csv")
  })
  let motion = load_motion_files(
    names.map(name => directory + "/" + name),
    kin,
    source_fps~,
    compute_body_features~,
    storage~,
    cache_dir~,
    max_gather_frames~,
    motion_cache_advice~,
    cache_advice_report~,
  )
  let identity : Json = {
    "format": "moonrobo.aligned-directory-catalog.v1",
    "names": motion.names.to_json(),
    "source_sha256": motion.source_sha256.to_json(),
    "source_fps": source_fps.to_json(),
  }
  {
    motion,
    manifest: identity,
    manifest_sha256: @artifacts.sha256(@utf8.encode(identity.stringify())),
    split: "train",
  }
}

///|
pub async fn load_motion_manifest(
  path : String,
  kin : Kinematics,
  split~ : String = "train",
  compute_body_features~ : Bool = true,
  storage~ : String = "eager",
  cache_dir~ : String = "",
  max_gather_frames~ : Int32 = 131072,
  motion_cache_advice~ : Bool = false,
  cache_advice_report~ : ((MotionCacheAdviceReport) -> Unit)? = None,
  max_sampler_bins~ : Int32? = None,
) -> LoadedMotion {
  validate_motion_sampler_cap(max_sampler_bins)
  guard max_sampler_bins is None || storage == "mmap" else {
    fail("motion sampler bin capacity requires mmap reference storage")
  }
  guard ["eager", "mmap"].contains(storage) else {
    fail("unsupported motion storage")
  }
  guard !motion_cache_advice || storage == "mmap" else {
    fail("motion cache advice requires bounded mmap reference storage")
  }
  guard storage != "mmap" || cache_dir != "" else {
    fail("bounded motion storage requires cache_dir")
  }
  let bytes = @fs.read_file(path).binary()
  let json = @json.parse(@utf8.decode(bytes))
  let catalog : MotionCatalog = @json.from_json(json)
  guard catalog.format == "moonrobo.aligned-motion-catalog.v1" &&
    catalog.quaternion_order == "xyzw" else {
    fail("unsupported motion manifest or quaternion order")
  }
  let by_id : Map[String, CatalogClip] = Map([])
  for row in catalog.clips {
    guard !by_id.contains(row.id) else {
      fail("duplicate manifest clip identifiers")
    }
    by_id[row.id] = row
  }
  guard catalog.splits.get(split) is Some(selected) else {
    fail("missing requested catalog split")
  }
  if max_sampler_bins is Some(limit) {
    // Every valid clip has at least one bin. Reject impossible catalog sizes
    // before constructing the per-selected-clip source/hash arrays.
    guard selected.length() <= limit else {
      fail("selected motion clip count exceeds sampler bin capacity")
    }
  }
  if storage == "eager" {
    require_native_eager_catalog_size(selected.length())
  }
  let clips : Array[MotionClip] = []
  let files : Array[String] = []
  let hashes : Array[String] = []
  let seen : Map[String, Bool] = {}
  for id in selected {
    guard !seen.contains(id) else { fail("duplicate split clip identifiers") }
    seen[id] = true
    guard by_id.get(id) is Some(row) else {
      fail("unknown split clip identifier")
    }
    guard row.layout == "root_xyz+quaternion_xyzw+g1_29_joint_angles" &&
      row.fps.unwrap_or(catalog.source_fps) == catalog.source_fps else {
      fail("motion catalog requires G1-retargeted CSV with common FPS")
    }
    let file = if row.path.has_prefix("/") {
      row.path
    } else {
      path_parent(path) + "/" + row.path
    }
    if storage == "mmap" {
      files.push(file)
      hashes.push(row.sha256)
    } else {
      let data = @fs.read_file(file).binary()
      let sha256 = @artifacts.sha256(data)
      guard sha256 == row.sha256 else { fail("motion SHA256 mismatch: " + id) }
      clips.push({
        name: id,
        sha256,
        rows: parse_motion_csv(@utf8.decode(data)),
      })
    }
  }
  {
    motion: if storage == "mmap" {
      load_streamed_motion(
        files,
        selected,
        hashes,
        kin,
        catalog.source_fps,
        cache_dir,
        compute_body_features,
        max_gather_frames,
        motion_cache_advice,
        cache_advice_report,
        max_sampler_bins~,
      )
    } else {
      MotionLibrary::new(
        clips,
        kin,
        source_fps=catalog.source_fps,
        compute_body_features~,
      )
    },
    manifest: json,
    manifest_sha256: @artifacts.sha256(bytes),
    split,
  }
}
