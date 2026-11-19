///|
fn Manifest::validate_resource_limits(self : Manifest) -> Unit raise {
  let profile = self.profile()
  let limits = bundle_limits(profile)
  guard self.files.length() >= 4 &&
    self.files.length() <= limits.files &&
    !self.shared_regions.is_empty() &&
    self.shared_regions.length() <= limits.regions else {
    fail("APIC file/shared-region counts exceed explicit capacity profile")
  }
  let mut bytes = 0L
  for region in self.shared_regions {
    bytes = add_bundle_bytes(
      bytes,
      region.bytes.to_int64(),
      capacity_profile=profile,
      union=true,
    )
    guard @utf8.encode(region.name).length() <= 1024 else {
      fail("APIC shared-region name exceeds 1024 bytes")
    }
  }
}

///|
/// Sizes here are verified disk sizes, while shared regions are the manifest's
/// numeric allocation union. The four graphs refer to one logical inventory,
/// but native loading may retain separate device copies for each graph. This
/// summary counts the logical union once as a lower bound, not actual resident
/// bytes. Neither value includes graph copies/mesh/JIT/solver scratch.
fn Manifest::resource_summary(
  self : Manifest,
  file_sizes : Map[String, Int64],
) -> Json raise {
  self.validate_resource_limits()
  let profile = self.profile()
  guard file_sizes.length() == self.files.length() else {
    fail("APIC resource summary requires the exact verified file inventory")
  }
  let mut disk_bytes = 0L
  let mut largest_file = 0L
  let hashes : Map[String, String] = {}
  for file in self.files {
    guard file_sizes.get(file.path) is Some(bytes) else {
      fail("APIC verified file size missing: " + file.path)
    }
    disk_bytes = add_bundle_bytes(disk_bytes, bytes, capacity_profile=profile)
    largest_file = largest_file.max(bytes)
    hashes[file.path] = file.sha256
  }
  let regions : Map[String, SharedRegion] = {}
  let bytes_by_dtype : Map[String, Int64] = {}
  let mut union_bytes = 0L
  let mut largest_region = 0L
  for region in self.shared_regions {
    union_bytes = add_bundle_bytes(
      union_bytes,
      region.bytes.to_int64(),
      capacity_profile=profile,
      union=true,
    )
    largest_region = largest_region.max(region.bytes.to_int64())
    regions[region.name] = region
    bytes_by_dtype[region.scalar_type] = bytes_by_dtype.get_or_default(
        region.scalar_type,
        0L,
      ) +
      region.bytes.to_int64()
  }
  let view_summary : Map[String, Json] = {}
  for name, view in self.views {
    guard regions.get(view.binding) is Some(region) else {
      fail("APIC view has no shared allocation: " + name)
    }
    let scalar = scalar_size(region.scalar_type).to_int64()
    let last = view.offset_elements.to_int64() +
      (self.num_envs - 1).to_int64() * view.row_stride_elements.to_int64() +
      (view.width - 1).to_int64() * view.component_stride_elements.to_int64()
    view_summary[name] = {
      "shape": [self.num_envs.to_json(), view.width.to_json()],
      "binding": view.binding.to_json(),
      "scalar_type": region.scalar_type.to_json(),
      "scalar_bytes": scalar.to_json(),
      "binding_bytes": region.bytes.to_json(),
      "offset_elements": view.offset_elements.to_json(),
      "row_stride_elements": view.row_stride_elements.to_json(),
      "component_stride_elements": view.component_stride_elements.to_json(),
      "last_byte_exclusive": ((last + 1L) * scalar).to_json(),
    }
  }
  let graphs = ["step", "reset", "context", "refresh"].mapi((i, role) => {
    let path = [
        self.graphs.step,
        self.graphs.reset,
        self.graphs.context,
        self.graphs.refresh,
      ][i]
    {
      "role": role.to_json(),
      "path": path.to_json(),
      "file_bytes": file_sizes.get_or_default(path, 0L).to_json(),
      "sha256": hashes.get_or_default(path, "").to_json(),
    }
  })
  {
    "format": "moonrobo.apic-resource-lower-bound.v1",
    "num_envs": self.num_envs.to_json(),
    "capacity_profile": Json(profile.name()),
    "file_count": self.files.length().to_json(),
    "bundle_disk_bytes": disk_bytes.to_json(),
    "largest_file_bytes": largest_file.to_json(),
    "shared_numeric_region_count": self.shared_regions.length().to_json(),
    "shared_numeric_union_bytes": union_bytes.to_json(),
    "shared_numeric_union_source": "verified_manifest_numeric_union",
    "shared_numeric_bytes_by_dtype": bytes_by_dtype.to_json(),
    "largest_shared_region_bytes": largest_region.to_json(),
    "shared_union_counted_once": true,
    "four_graph_shared_allocation_lower_bound_bytes": union_bytes.to_json(),
    "graphs": graphs.to_json(),
    "views": view_summary.to_json(),
    "cuda_scratch_bytes": Json::null(),
    "private_graph_allocation_bytes": Json::null(),
    "opaque_mesh_allocation_bytes": Json::null(),
    "driver_jit_allocation_bytes": Json::null(),
    "complete_peak_estimate": false,
    "replaces_training_memory_admission": false,
    "validation_chunk_bytes": 65536,
    "input_files_must_remain_immutable_during_native_replay": true,
  }
}
