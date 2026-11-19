///|
pub(all) struct SuggestedBlockSize {
  block_size : Int32
  min_grid_size : Int32
} derive(ToJson)

///|
pub extend SuggestedBlockSize with ToJson::{to_json}

///|
#borrow(handle, block, grid)
extern "c" fn suggested_block_size_ffi(
  handle : Handle,
  shared_memory : Int32,
  block : Ref[Int32],
  grid : Ref[Int32],
) -> Int32 = "moonrobo_dispatch_suggested_block_size"

///|
/// Queries genuine Warp/CUDA occupancy for this actual loaded forward kernel.
/// It is an explicit native operation, forbidden during capture. It does not
/// initialize another device, compile or execute a kernel, or guess dimensions.
/// Older ABI-3 plugins without the additive query fail explicitly.
pub fn Kernel::suggested_block_size(
  self : Kernel,
  shared_memory_bytes~ : Int32 = 0,
) -> SuggestedBlockSize raise {
  guard shared_memory_bytes >= 0 else {
    fail("negative occupancy shared-memory size")
  }
  self.0.checked()
  let block = Ref(0)
  let grid = Ref(0)
  self.0.checked(
    status=suggested_block_size_ffi(self.0, shared_memory_bytes, block, grid),
  )
  guard block.val > 0 && block.val <= 1024 && grid.val > 0 else {
    fail("native Warp occupancy returned invalid dimensions")
  }
  { block_size: block.val, min_grid_size: grid.val, }
}
