///|
test "replay payload accounting distinguishes lazy storage from capacity" {
  let replay = @learning_aligned.ReplayBuffer::new(1000, 4096)
  let usage = replay.storage_usage()
  assert_eq(usage.logical_records, 0L)
  assert_eq(usage.allocated_records, 0L)
  assert_eq(usage.slab_count, 0)
  assert_eq(usage.capacity_records, 4096000L)
  assert_eq(usage.capacity_payload_bytes, 7708672000L)
  assert_eq(usage.format, "moonrobo.replay-f64-slab-storage.v1")
}
