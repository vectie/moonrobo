///|
/// All file reading and exact argument validation happen before CUDA setup.
async fn prepare(config : CaptureConfig) -> Prepared {
  guard config.device_ordinal >= 0 &&
    config.architecture > 0 &&
    !config.output.is_empty() &&
    !@fs.exists(config.output) &&
    @contracts.sha256_hex(config.compiled_manifest_sha256) else {
    fail(
      "kernel capture requires explicit CUDA device/architecture, pinned manifest and fresh output",
    )
  }
  let directory = @fs.realpath(config.compiled_directory)
  let manifest_bytes = @fs.read_file(directory + "/manifest.json").binary()
  guard @artifacts.sha256(manifest_bytes) == config.compiled_manifest_sha256 else {
    fail("kernel capture: compiled manifest SHA256 differs")
  }
  let manifest = @json.parse(@utf8.decode(manifest_bytes))
  let notice = @fs.read_file(directory + "/NOTICE").binary()
  guard !notice.is_empty() else {
    fail("kernel capture: compiled artifact NOTICE is missing")
  }
  guard text(manifest, "format") == "moonrobo-g1-concrete-kernel-module-v1" &&
    text(manifest, "producer") == "moonbit-typed-g1-lowerer" &&
    text(manifest, "warp_version") == "1.17.0" &&
    text(manifest, "isaaclab_revision") == @kernels.isaaclab_revision() &&
    text(manifest, "launch_abi") ==
    "warp-1.17-64bit-launch-bounds-array-by-value" &&
    json_field(manifest, "launch_coord_mult") == Json(1) &&
    json_field(manifest, "generated_adjoint") == Json(false) &&
    json_field(manifest, "warp_meta_generated") == Json(false) else {
    fail("kernel capture: unsupported compiled receipt/ABI/version")
  }
  let request : @kernels.SpecializationRequest = @json.from_json(
    json_field(manifest, "request"),
  )
  let specialization = @kernels.lower(request)
  guard text(manifest, "specialization_sha256") ==
    specialization.specialization_sha256 &&
    text(manifest, "source_sha256") == specialization.source_sha256 &&
    json_field(manifest, "entries") == specialization.entries.to_json() &&
    text(manifest, "source_path") == "kernels.cu" else {
    fail(
      "kernel capture: compiled specialization/source/typed entries differ from current lowerer",
    )
  }
  let source = @fs.read_file(directory + "/kernels.cu").binary()
  guard @artifacts.sha256(source) == specialization.source_sha256 &&
    source == @utf8.encode(specialization.source) else {
    fail("kernel capture: actual CUDA source differs from specialization")
  }
  let image_info = json_field(manifest, "image")
  let image_kind = text(image_info, "kind")
  let image_name = text(image_info, "path")
  let image_sha256 = text(image_info, "sha256")
  guard (image_kind == "ptx" || image_kind == "cubin") &&
    image_name == "module." + image_kind &&
    @contracts.sha256_hex(image_sha256) else {
    fail("kernel capture: invalid compiled image identity")
  }
  let image_path = directory + "/" + image_name
  let image = @fs.read_file(image_path).binary()
  guard !image.is_empty() && @artifacts.sha256(image) == image_sha256 else {
    fail("kernel capture: actual compiled image SHA256 differs")
  }
  let options : Array[String] = @json.from_json(
    json_field(json_field(manifest, "compiler"), "options"),
  )
  let architecture = (if image_kind == "ptx" { "compute_" } else { "sm_" }) +
    config.architecture.to_string()
  let actual_arch = options.filter(fn(option) {
    option.has_prefix("--gpu-architecture=") || option.has_prefix("-arch=")
  })
  guard actual_arch.length() == 1 &&
    (
      actual_arch[0] == "--gpu-architecture=" + architecture ||
      actual_arch[0] == "-arch=" + architecture
    ) else {
    fail(
      "kernel capture: explicit device architecture differs from compiled target",
    )
  }
  let selected = specialization.entries.filter(fn(entry) {
    entry.key == config.kernel_key
  })
  guard selected.length() == 1 else {
    fail("kernel capture: selected kernel absent from compiled specialization")
  }
  let entry = selected[0]
  guard config.arguments.length() == entry.parameters.length() else {
    fail(
      "kernel capture: named argument cardinality differs from compiled signature",
    )
  }
  let buffers : Array[LoadedBuffer] = []
  let names : Array[String] = []
  let mut total = 0
  for input in config.buffers {
    guard !input.name.is_empty() &&
      !input.name.contains("\u{0}") &&
      !names.contains(input.name) &&
      @contracts.sha256_hex(input.sha256) else {
      fail("kernel capture: invalid/duplicated raw buffer identity")
    }
    names.push(input.name)
    let width = scalar_bytes(input.scalar_type)
    let bytes = @fs.read_file(@fs.realpath(input.path)).binary()
    guard !bytes.is_empty() &&
      bytes.length() <= 268435456 &&
      total <= 536870912 - bytes.length() &&
      bytes.length() % width == 0 &&
      @artifacts.sha256(bytes) == input.sha256 else {
      fail(
        "kernel capture: raw buffer SHA256/capacity/alignment or 512 MiB total limit violated",
      )
    }
    total += bytes.length()
    guard input.scalar_type != "bool" ||
      bytes.iter().all(byte => byte == 0 || byte == 1) else {
      fail("kernel capture: raw C++ bool buffer contains a noncanonical byte")
    }
    buffers.push({ input, bytes, scalar_bytes: width, })
  }
  let arguments : Array[TypedArgument] = []
  let used : Array[String] = []
  let writes : Array[String] = []
  for parameter in entry.parameters {
    guard config.arguments.get(parameter.name) is Some(value) else {
      fail("kernel capture: missing argument " + parameter.name)
    }
    if parameter.kind == "array" {
      guard value is Object(fields) &&
        fields.length() == 4 &&
        ["buffer", "shape", "byte_strides", "offset_bytes"].all(key => {
          fields.contains(key)
        }) else {
        fail(
          "kernel capture: array arguments require exactly buffer/shape/byte_strides/offset_bytes",
        )
      }
      let array : ArrayInput = @json.from_json(value)
      let owners = buffers.filter(fn(buffer) {
        buffer.input.name == array.buffer
      })
      guard owners.length() == 1 else {
        fail("kernel capture: array argument references unknown owned buffer")
      }
      let owner = owners[0]
      let (scalar, width) = element(parameter.dtype)
      guard owner.input.scalar_type == scalar else {
        fail(
          "kernel capture: array primitive dtype differs from compiled parameter",
        )
      }
      validate_array(
        array,
        parameter.rank,
        width,
        owner.scalar_bytes,
        owner.bytes.length(),
      )
      guard array.shape == expected_shape(entry, parameter, request) else {
        fail(
          "kernel capture: actual array extents do not match concrete specialization",
        )
      }
      if parameter.access != "input" {
        guard !used.contains(array.buffer) && !writes.contains(array.buffer) else {
          fail(
            "kernel capture: writable kernel arguments require distinct owned buffers",
          )
        }
        writes.push(array.buffer)
        validate_writable(array, width)
      } else {
        guard !writes.contains(array.buffer) else {
          fail("kernel capture: input aliases writable kernel argument")
        }
      }
      if parameter.name == "user_to_backend" ||
        parameter.name == "backend_to_user" ||
        parameter.name == "dst_to_src" ||
        parameter.name == "joint_indices" {
        validate_index_data(array, owner.bytes, array.shape[0])
      }
      arguments.push(Array(array, width))
      if !used.contains(array.buffer) {
        used.push(array.buffer)
      }
    } else {
      match parameter.dtype {
        "int32" => {
          let integer : Int32 = @json.from_json(value)
          guard parameter.name != "num_bodies" || integer == request.num_bodies else {
            fail(
              "kernel capture: scalar num_bodies differs from specialization",
            )
          }
          arguments.push(Integer(integer))
        }
        "bool" => arguments.push(Boolean(@json.from_json(value)))
        _ => fail("kernel capture: unsupported compiled scalar parameter")
      }
    }
  }
  guard used.length() == buffers.length() else {
    fail("kernel capture: unused raw buffers are not captured inputs")
  }
  {
    entry,
    specialization,
    manifest,
    manifest_bytes,
    notice,
    image,
    image_path,
    image_kind,
    image_sha256,
    buffers,
    arguments,
    dispatch_plugin: @fs.realpath(config.dispatch_plugin),
    writer_plugin: @fs.realpath(config.writer_plugin),
    warp_library: @fs.realpath(config.warp_library),
  }
}
