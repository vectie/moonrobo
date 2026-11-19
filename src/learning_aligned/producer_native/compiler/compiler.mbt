///|
/// Owns a dynamically loaded NVRTC library, without creating a CUDA context.
pub type Compiler

///|
type Compilation

///|
pub(all) enum ImageKind {
  Ptx
  Cubin
} derive(Debug, Eq)

///|
pub(all) struct Version {
  major : Int32
  minor : Int32
} derive(Debug, Eq, ToJson)

///|
pub(all) struct Header {
  include_name : String
  source : String
} derive(Debug)

///|
pub(all) struct CompileRequest {
  source : String
  program_name : String
  headers : Array[Header]
  options : Array[String]
  kind : ImageKind
} derive(Debug)

///|
pub(all) struct CompiledModule {
  image : Bytes
  log : String
  version : Version
  kind : ImageKind
} derive(Debug)

///|
pub suberror CompileError {
  Invalid(String)
  Failed(message~ : String, log~ : String)
} derive(Debug)

///|
fn text(value : String) -> Bytes raise {
  guard !value.contains("\u{0}") else {
    raise CompileError::Invalid("embedded NUL in NVRTC input")
  }
  @utf8.encode(value)
}

///|
#borrow(path)
extern "c" fn open_raw(path : Bytes) -> Compiler = "mr_apic_nvrtc_open"

///|
#borrow(compiler)
extern "c" fn open_error(compiler : Compiler) -> Bytes = "mr_apic_nvrtc_error"

///|
#borrow(compiler)
extern "c" fn version_major(compiler : Compiler) -> Int32 = "mr_apic_nvrtc_major"

///|
#borrow(compiler)
extern "c" fn version_minor(compiler : Compiler) -> Int32 = "mr_apic_nvrtc_minor"

///|
#borrow(compiler, source, name, headers, names, options)
extern "c" fn compile_raw(
  compiler : Compiler,
  source : Bytes,
  name : Bytes,
  headers : FixedArray[Bytes],
  names : FixedArray[Bytes],
  options : FixedArray[Bytes],
  kind : Int32,
) -> Compilation = "mr_apic_nvrtc_compile"

///|
#borrow(result)
extern "c" fn compile_error(result : Compilation) -> Bytes = "mr_apic_nvrtc_compile_error"

///|
#borrow(result)
extern "c" fn compile_log(result : Compilation) -> Bytes = "mr_apic_nvrtc_compile_log"

///|
#borrow(result)
extern "c" fn compile_image(result : Compilation) -> Bytes = "mr_apic_nvrtc_image"

///|
/// This explicit operation loads the selected native compiler and its native
/// dependencies. It does not invoke Python or initialize the CUDA driver.
pub fn Compiler::open(nvrtc_library : String) -> Compiler raise {
  guard !nvrtc_library.is_empty() else {
    raise CompileError::Invalid("explicit NVRTC library required")
  }
  let compiler = open_raw(text(nvrtc_library))
  let error = @utf8.decode_lossy(open_error(compiler))
  guard error.is_empty() else { raise CompileError::Invalid(error) }
  compiler
}

///|
pub fn Compiler::version(self : Compiler) -> Version {
  { major: version_major(self), minor: version_minor(self), }
}

///|
/// Compiles already generated CUDA C++ source. Warp AST specialization, Newton
/// kernel generation, dispatch planning and APIC capture remain separate stages.
pub fn Compiler::compile(
  self : Compiler,
  request : CompileRequest,
) -> CompiledModule raise {
  guard !request.source.is_empty() && !request.program_name.is_empty() else {
    raise CompileError::Invalid(
      "nonempty CUDA source and program_name required",
    )
  }
  let names : Map[String, Unit] = {}
  for header in request.headers {
    guard !header.include_name.is_empty() &&
      !names.contains(header.include_name) else {
      raise CompileError::Invalid("empty or duplicate include name")
    }
    names[header.include_name] = ()
  }
  for option in request.options {
    guard !option.is_empty() else {
      raise CompileError::Invalid("empty NVRTC option")
    }
  }
  let sources = request.headers.map(h => text(h.source))
  let includes = request.headers.map(h => text(h.include_name))
  let options = request.options.map(text)
  let result = compile_raw(
    self,
    text(request.source),
    text(request.program_name),
    FixedArray::makei(sources.length(), i => sources[i]),
    FixedArray::makei(includes.length(), i => includes[i]),
    FixedArray::makei(options.length(), i => options[i]),
    match request.kind {
      Ptx => 0
      Cubin => 1
    },
  )
  let error = @utf8.decode_lossy(compile_error(result))
  let log = @utf8.decode_lossy(compile_log(result))
  guard error.is_empty() else {
    raise CompileError::Failed(message=error, log~)
  }
  {
    image: compile_image(result),
    log,
    version: self.version(),
    kind: request.kind,
  }
}
