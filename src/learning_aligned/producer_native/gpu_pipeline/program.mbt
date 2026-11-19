///|
/// Compilation of the explicit program is host-only and precedes CUDA setup.
fn compile_call(
  launch : Launch,
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
) -> Call raise {
  guard modules.get(launch.module) is Some(module) &&
    module.entries.get(launch.entry) is Some(entry) &&
    launch.arguments.length() == entry.parameters.length() else {
    fail("unknown GPU module/entry or argument cardinality differs")
  }
  let arguments : Array[Argument] = []
  let named : Map[String, View] = {}
  let intervals : Array[(String, UInt64, UInt64, Bool, String)] = []
  for param in entry.parameters {
    guard launch.arguments.get(param.name) is Some(value) else {
      fail("missing kernel argument: " + param.name)
    }
    if param.kind == "array" {
      let view = strict_view(value)
      guard view.dtype == param.dtype && view.shape.length() == param.rank else {
        fail("array dtype/rank differs from actual generated signature")
      }
      let (lo, hi) = span(view, buffers)
      let writes = param.access != "input"
      if writes {
        writable(view)
      }
      for (owner, start, end, other_writes, other_name) in intervals {
        let inplace_sparse = module.kind ==
          "moonrobo-native-mixed-sparse-solver-module-v1" &&
          (
            (param.name == "solution" && other_name == "rhs") ||
            (param.name == "rhs" && other_name == "solution")
          ) &&
          view.to_json() == named[other_name].to_json()
        let inplace_metric = module.kind ==
          "moonrobo-native-solver-metrics-module-v1" &&
          ["copy-backbone-rhs", "block-solve", "efm0-solve"].contains(entry.key) &&
          (
            (param.name == "res" && other_name == "rhs") ||
            (param.name == "rhs" && other_name == "res")
          ) &&
          view.to_json() == named[other_name].to_json()
        guard owner != view.buffer ||
          hi == lo ||
          end == start ||
          !(writes || other_writes) ||
          hi <= start ||
          lo >= end ||
          inplace_sparse ||
          inplace_metric else {
          fail("kernel writable views overlap another argument")
        }
      }
      intervals.push((view.buffer, lo, hi, writes, param.name))
      let (_, width) = element(view.dtype)
      arguments.push(Array(view, width))
      named[param.name] = view
    } else {
      arguments.push(
        match param.dtype {
          "int32" => Int32(@json.from_json(value))
          "bool" => Boolean(@json.from_json(value))
          "float32" => {
            let number : Double = @json.from_json(value)
            let f = Float::from_double(number)
            guard finite(number) && !f.is_nan() && !f.is_inf() else {
              fail("nonfinite/overflow float32 scalar")
            }
            Float32(f)
          }
          "float64" => {
            let number : Double = @json.from_json(value)
            guard finite(number) else { fail("nonfinite float64 scalar") }
            Float64(number)
          }
          _ => fail("unsupported generated scalar ABI")
        },
      )
    }
  }
  let call = { module: module.id, entry, arguments, named, }
  validate_call(call, module, buffers, immutable)
  call
}

///|
fn condition(view : View, buffers : Map[String, HostBuffer]) -> Unit raise {
  ignore(span(view, buffers))
  guard view.dtype == "int32" && view.shape == [1] && view.byte_strides == [4] else {
    fail("device graph predicate requires one actual int32 owner view")
  }
}

///|
fn compile_program(
  commands : Array[Command],
  modules : Map[String, Module],
  buffers : Map[String, HostBuffer],
  immutable : Map[String, Unit],
  mode : String,
  depth : Int32,
  narrowphase : Ref[Call?],
  nxn : Ref[Int32],
  convergence_tail~ : Bool = false,
) -> Array[Op] raise {
  let result : Array[Op] = []
  for index, command in commands {
    result.push(
      match command.operation {
        "launch" => {
          let call = compile_call(
            @json.from_json(command.parameters),
            modules,
            buffers,
            immutable,
          )
          if modules[call.module].kind ==
            "moonrobo-native-primitive-contact-module-v1" {
            guard depth == 0 && narrowphase.val is None else {
              fail(
                "primitive narrowphase must have one top-level launch in the terminal contact suffix",
              )
            }
            narrowphase.val = Some(call)
          }
          if call.entry.key == "nxn-broadphase" {
            nxn.val += 1
            guard depth == 0 && nxn.val == 1 else {
              fail(
                "NXN atomic counter profile permits one top-level producer only",
              )
            }
          }
          if modules[call.module].kind ==
            "moonrobo-device-convergence-module-v1" {
            guard convergence_tail &&
              depth == 1 &&
              index == commands.length() - 1 else {
              fail(
                "device convergence producer must be the unconditional final launch of one top-level WHILE",
              )
            }
          }
          if modules[call.module].kind == "moonrobo-native-convex-gjk-module-v1" {
            guard depth == 0 && index == commands.length() - 1 else {
              fail(
                "convex distance stage must be a final top-level launch before host result gate",
              )
            }
          }
          if modules[call.module].kind ==
            "moonrobo-native-convex-contact-module-v1" {
            guard depth == 0 else {
              fail(
                "convex contact writing requires a terminal top-level launch",
              )
            }
          }
          if modules[call.module].kind ==
            "moonrobo-native-newton-solver-module-v1" &&
            [
              "initialize-controls", "initialize-state", "cg-search-init", "unconstrained",
            ].contains(call.entry.key) {
            guard depth == 0 else {
              fail("solver initialization must be unconditional and top-level")
            }
          }
          if modules[call.module].kind == "moonrobo-mathdx-tile-module-v1" {
            guard depth == 0 else {
              fail(
                "MathDx tiles currently require a top-level launch; loop status persistence is not implemented",
              )
            }
          }
          if modules[call.module].kind ==
            "moonrobo-native-solver-adapters-module-v1" &&
            call.entry.key == "incremental-initialize" {
            guard depth == 0 else {
              fail(
                "incremental state initialization must be unconditional and top-level",
              )
            }
          }
          Kernel(call)
        }
        "copy" => {
          let copy : Copy = @json.from_json(command.parameters)
          memory_range(
            copy.source,
            copy.source_offset,
            copy.count_bytes,
            buffers,
          )
          memory_range(
            copy.destination,
            copy.destination_offset,
            copy.count_bytes,
            buffers,
          )
          guard copy.count_bytes > 0UL &&
            (
              copy.source != copy.destination ||
              copy.source_offset + copy.count_bytes <= copy.destination_offset ||
              copy.destination_offset + copy.count_bytes <= copy.source_offset
            ) else {
            fail("device memcpy must be positive and nonoverlapping")
          }
          guard buffers[copy.source].scalar_type ==
            buffers[copy.destination].scalar_type else {
            fail("copy primitive types differ; no implicit conversion")
          }
          let width = scalar_width(buffers[copy.destination].scalar_type).to_uint64()
          guard copy.source_offset % width == 0UL &&
            copy.destination_offset % width == 0UL &&
            copy.count_bytes % width == 0UL else {
            fail("device copy would split primitive values")
          }
          CopyBytes(copy)
        }
        "zero" => {
          let zero : Zero = @json.from_json(command.parameters)
          memory_range(
            zero.buffer,
            zero.offset_bytes,
            zero.count_bytes,
            buffers,
          )
          let width = scalar_width(buffers[zero.buffer].scalar_type).to_uint64()
          guard zero.count_bytes > 0UL &&
            zero.offset_bytes % width == 0UL &&
            zero.count_bytes % width == 0UL else {
            fail("device zero would split primitive values")
          }
          ZeroBytes(zero)
        }
        "if" => {
          guard mode == "capture" else {
            fail("conditional commands require actual CUDA graph capture")
          }
          let branch : Branch = @json.from_json(command.parameters)
          condition(branch.condition, buffers)
          If(
            branch.condition,
            compile_program(
              branch.on_true,
              modules,
              buffers,
              immutable,
              mode,
              depth + 1,
              narrowphase,
              nxn,
            ),
            compile_program(
              branch.on_false,
              modules,
              buffers,
              immutable,
              mode,
              depth + 1,
              narrowphase,
              nxn,
            ),
          )
        }
        "while" => {
          guard mode == "capture" else {
            fail("device WHILE requires actual CUDA graph capture")
          }
          let repeat : Loop = @json.from_json(command.parameters)
          condition(repeat.condition, buffers)
          guard !repeat.body.is_empty() else {
            fail("device WHILE body is empty")
          }
          let last = repeat.body[repeat.body.length() - 1]
          let real_convergence = last.operation == "launch"
          if real_convergence {
            let launch : Launch = @json.from_json(last.parameters)
            guard depth == 0 &&
              modules.get(launch.module) is Some(module) &&
              module.kind == "moonrobo-device-convergence-module-v1" else {
              fail(
                "multi-iteration WHILE requires a real supported device convergence producer",
              )
            }
          } else {
            guard last.operation == "zero" else {
              fail(
                "WHILE requires a convergence producer or final predicate clear",
              )
            }
            let zero : Zero = @json.from_json(last.parameters)
            guard zero.buffer == repeat.condition.buffer &&
              zero.offset_bytes == repeat.condition.offset_bytes &&
              zero.count_bytes == 4UL else {
              fail("one-shot WHILE final zero must clear its actual predicate")
            }
          }
          let body = compile_program(
            repeat.body,
            modules,
            buffers,
            immutable,
            mode,
            depth + 1,
            narrowphase,
            nxn,
            convergence_tail=real_convergence,
          )
          if real_convergence {
            guard body[body.length() - 1] is Kernel(call) &&
              call.named["nsolving"].to_json() == repeat.condition.to_json() else {
              fail(
                "device convergence must update the exact WHILE predicate view",
              )
            }
          }
          While(repeat.condition, body)
        }
        _ => fail("unknown GPU command")
      },
    )
  }
  result
}

///|
/// Index arrays proven from their initial bytes may never be rewritten by
/// another operation. Whole-owner protection deliberately rejects alias tricks.
fn validate_writes(
  program : Array[Op],
  immutable : Map[String, Unit],
) -> Unit raise {
  for op in program {
    match op {
      Kernel(call) =>
        for param in call.entry.parameters {
          if param.kind == "array" && param.access != "input" {
            guard !immutable.contains(call.named[param.name].buffer) else {
              fail(
                "program writes an owner whose initial indices were used in a bounds proof",
              )
            }
          }
        }
      CopyBytes(copy) => {
        guard !immutable.contains(copy.destination) else {
          fail("copy writes immutable index owner")
        }
      }
      ZeroBytes(zero) => {
        guard !immutable.contains(zero.buffer) else {
          fail("zero writes immutable index owner")
        }
      }
      If(_, yes, no) => {
        validate_writes(yes, immutable)
        validate_writes(no, immutable)
      }
      While(_, body) => validate_writes(body, immutable)
    }
  }
}

///|
async fn prepare(
  config : Config,
  initial_buffers : Array[HostBuffer],
) -> Prepared {
  ignore(decode_config(config.to_json()))
  guard config.device_ordinal >= 0 &&
    config.architecture > 0 &&
    !config.output.is_empty() &&
    !@fs.exists(config.output) &&
    (config.mode == "eager" || config.mode == "capture") &&
    (config.mode == "capture" || !config.launch_captured_graph) &&
    !config.program.is_empty() else {
    fail(
      "explicit device/architecture, fresh output and valid eager/capture mode required",
    )
  }
  let modules : Map[String, Module] = {}
  let images : Map[String, Unit] = {}
  for input in config.modules {
    guard !modules.contains(input.id) else {
      fail("duplicate compiled module ID")
    }
    let module = read_module(input, config.architecture)
    guard !images.contains(module.image_sha256) else {
      fail("same native image must use one module identity")
    }
    modules[input.id] = module
    images[module.image_sha256] = ()
  }
  guard !modules.is_empty() else {
    fail("at least one genuine compiled module required")
  }
  let buffers = read_buffers(config)
  let total = Ref(
    buffers.values().fold(init=0, fn(sum, item) { sum + item.bytes.length() }),
  )
  for buffer in initial_buffers {
    add_buffer(buffers, buffer, total)
  }
  guard !buffers.is_empty() else {
    fail("GPU pipeline requires explicit owned initial bytes")
  }
  let immutable : Map[String, Unit] = {}
  let narrowphase = Ref(None)
  let program = compile_program(
    config.program,
    modules,
    buffers,
    immutable,
    config.mode,
    0,
    narrowphase,
    Ref(0),
  )
  validate_writes(program, immutable)
  validate_solver_adapter_order(program, modules)
  validate_cg_preconditioners(program, modules)
  validate_reference_newton_order(program, modules)
  freeze_newton_inputs(program, modules, {})
  let convex_contacts = validate_terminal_contacts(
    program,
    modules,
    narrowphase.val,
  )
  let counters : Map[String, String] = {}
  protect_counters(program, counters, true)
  protect_counters(program, counters, false)
  let controls : Map[String, String] = {}
  let convergence : Array[Call] = []
  protect_convergence(program, modules, controls, convergence, true)
  let initialized : Map[String, Call] = {}
  let control_initializers : Map[String, Call] = {}
  let line_flags : Map[String, StickyStatus] = {}
  collect_newton_initialization(
    program, modules, buffers, initialized, control_initializers, line_flags, 0,
  )
  protect_newton_line_flags(program, modules, line_flags)
  validate_newton_transitions(
    initialized, modules, buffers, convergence, control_initializers,
  )
  let initializers = validate_cg_initializers(
    program, modules, buffers, convergence,
  )
  protect_convergence(
    program,
    modules,
    controls,
    [],
    false,
    initializers~,
    control_initializers~,
  )
  let stage_controls : Map[String, String] = {}
  let tiles : Array[Call] = []
  let convex = Ref(None)
  protect_stages(program, modules, stage_controls, tiles, convex, true)
  protect_stages(program, modules, stage_controls, [], Ref(None), false)
  let solver_controls : Map[String, StickyStatus] = {}
  protect_solver_status(program, modules, buffers, solver_controls, true)
  protect_solver_status(program, modules, buffers, solver_controls, false)
  {
    modules,
    buffers,
    program,
    narrowphase: narrowphase.val,
    convergence,
    convex: convex.val,
    convex_contacts,
    tiles,
    sticky_status: solver_controls.values().collect(),
    line_flags: line_flags.values().collect(),
    dispatch_plugin: @fs.realpath(config.dispatch_plugin),
    writer_plugin: @fs.realpath(config.writer_plugin),
    warp_library: @fs.realpath(config.warp_library),
  }
}
