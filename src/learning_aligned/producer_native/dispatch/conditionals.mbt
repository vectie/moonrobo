///|
#borrow(context, condition)
extern "c" fn conditional_begin_ffi(
  context : Handle,
  condition : Handle,
  offset : UInt64,
  state : UInt64,
  is_while : Int32,
  use_ptx : Int32,
  has_true : Int32,
  has_false : Int32,
) -> Handle = "moonrobo_dispatch_conditional_begin"

///|
#borrow(handle)
extern "c" fn conditional_enter_ffi(handle : Handle, branch : Int32) -> Int32 = "moonrobo_dispatch_conditional_enter"

///|
#borrow(handle)
extern "c" fn conditional_leave_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_conditional_leave"

///|
#borrow(handle)
extern "c" fn conditional_finish_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_conditional_finish"

///|
fn condition_view(condition : TypedView) -> Unit raise {
  guard condition.scalar_type == I32 &&
    condition.count == 1 &&
    condition.components == 1 &&
    condition.stride == 4 else {
    fail("conditional capture requires one retained int32 condition element")
  }
  condition.buffer.0.checked()
}

///|
/// Capture genuine dynamic CUDA/APIC IF branches. Requires a live outer CUDA
/// graph capture, matching nonzero APIC state, and driver/toolkit >=12.4.
/// Synchronous callbacks build graph bodies once; they do not select a host
/// branch. Failure requires discarding the partially modified parent graph.
pub fn Context::capture_if(
  self : Context,
  condition : TypedView,
  capture_state~ : UInt64,
  on_true? : () -> Unit raise,
  on_false? : () -> Unit raise,
  use_ptx~ : Bool = false,
) -> Unit raise {
  self.0.checked()
  condition_view(condition)
  guard on_true is Some(_) || on_false is Some(_) else {
    fail("at least one conditional branch callback is required")
  }
  let token = conditional_begin_ffi(
    self.0,
    condition.buffer.0,
    condition.offset,
    capture_state,
    0,
    if use_ptx {
      1
    } else {
      0
    },
    if on_true is Some(_) {
      1
    } else {
      0
    },
    if on_false is Some(_) {
      1
    } else {
      0
    },
  )
  defer close_ffi(token)
  token.checked()
  if on_true is Some(body) {
    token.checked(status=conditional_enter_ffi(token, 0))
    body()
    token.checked(status=conditional_leave_ffi(token))
  }
  if on_false is Some(body) {
    token.checked(status=conditional_enter_ffi(token, 1))
    body()
    token.checked(status=conditional_leave_ffi(token))
  }
  token.checked(status=conditional_finish_ffi(token))
  ignore(condition.buffer.size())
}

///|
/// Capture actual CUDA/APIC WHILE. The callback builds one loop-body graph;
/// replay reevaluates the device condition after each body execution using the
/// native conditional handle. The body must update the int32 condition so the
/// runtime loop can terminate. There is no fixed iteration count or fallback.
pub fn Context::capture_while(
  self : Context,
  condition : TypedView,
  body : () -> Unit raise,
  capture_state~ : UInt64,
  use_ptx~ : Bool = false,
) -> Unit raise {
  self.0.checked()
  condition_view(condition)
  let token = conditional_begin_ffi(
    self.0,
    condition.buffer.0,
    condition.offset,
    capture_state,
    1,
    if use_ptx {
      1
    } else {
      0
    },
    1,
    0,
  )
  defer close_ffi(token)
  token.checked()
  token.checked(status=conditional_enter_ffi(token, 0))
  body()
  token.checked(status=conditional_leave_ffi(token))
  token.checked(status=conditional_finish_ffi(token))
  ignore(condition.buffer.size())
}

///|
/// Owns the real CUDA graph and its lazily instantiated executable, retaining
/// all native dispatch allocations/modules until the graph is released.
pub struct Graph(Handle)

///|
#borrow(context)
extern "c" fn graph_begin_ffi(context : Handle, state : UInt64) -> Handle = "moonrobo_dispatch_graph_begin"

///|
#borrow(handle)
extern "c" fn graph_end_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_graph_end"

///|
#borrow(handle)
extern "c" fn graph_launch_ffi(handle : Handle) -> Int32 = "moonrobo_dispatch_graph_launch"

///|
/// Start/end a genuine owned CUDA outer graph using the official Warp C API.
/// The caller owns an already active APIC Writer and must keep it alive through
/// this synchronous callback. Callback failures discard the partial graph and
/// poison the native session; no graph is returned as a successful fallback.
pub fn Context::capture_graph(
  self : Context,
  body : () -> Unit raise,
  capture_state~ : UInt64,
) -> Graph raise {
  self.0.checked()
  let token = graph_begin_ffi(self.0, capture_state)
  errdefer close_ffi(token)
  token.checked()
  body()
  token.checked(status=graph_end_ffi(token))
  Graph(token)
}

///|
/// Instantiate and launch the actual CUDA graph outside APIC/CUDA capture.
/// Device work is asynchronous; Context::synchronize observes completion.
pub fn Graph::launch(self : Graph) -> Unit raise {
  self.0.checked(status=graph_launch_ffi(self.0))
}

///|
pub fn Graph::close(self : Graph) -> Unit {
  close_ffi(self.0)
}
