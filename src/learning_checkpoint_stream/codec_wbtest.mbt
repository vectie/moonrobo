///|
async test "F64LE streams across 64 KiB, preserves raw bits, and rejects damage" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-checkpoint-blob-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let payload_nan = 0x7ff8000000000042L.reinterpret_as_double()
    let original = Array::makei(8193, i => {
      if i == 0 {
        -0.0
      } else if i == 8192 {
        payload_nan
      } else {
        i.to_double() / 7.0
      }
    })
    let descriptor = write_f64le(root, "weights.f64", [8193], (offset, n) => {
      Array::makei(n, i => original[offset.to_int() + i])
    })
    assert_eq(descriptor.dtype, "f64le")
    assert_eq(descriptor.count, 8193L)
    assert_eq(descriptor.byte_length, 8193L * 8L)
    verify_blob(root, descriptor)
    let restored : Array[Double] = []
    read_f64le(root, descriptor, (_, values) => {
      for value in values {
        restored.push(value)
      }
    })
    assert_eq(restored.length(), original.length())
    for i in 0..<original.length() {
      assert_eq(
        restored[i].reinterpret_as_int64(),
        original[i].reinterpret_as_int64(),
      )
    }
    let corrupt = @fs.open(root + "/weights.f64", mode=ReadWrite)
    corrupt.write_at(b"\xff", position=0L)
    corrupt.close()
    try verify_blob(root, descriptor) catch {
      _ => ()
    } noraise {
      _ => fail("corrupt F64LE blob was accepted")
    }
    try read_f64le(root, descriptor, (_, _) => ()) catch {
      _ => ()
    } noraise {
      _ => fail("corrupt F64LE blob was decoded")
    }
  }
}

///|
async test "I32LE and U8 stream across chunks; empty tensors are valid" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-checkpoint-types-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let integers : Array[Int32] = Array::makei(16385, i => {
      if i == 0 {
        -2147483648
      } else {
        i - 12000
      }
    })
    let signed = write_i32le(root, "indices.i32", [16385], (offset, n) => {
      Array::makei(n, i => integers[offset.to_int() + i])
    })
    let restored_signed : Array[Int32] = []
    read_i32le(root, signed, (_, chunk) => {
      for value in chunk {
        restored_signed.push(value)
      }
    })
    assert_eq(restored_signed, integers)
    let flags = Array::makei(65537, i => (i % 251).to_byte())
    let unsigned = write_u8(root, "flags.u8", [65537], (offset, n) => {
      Array::makei(n, i => flags[offset.to_int() + i])
    })
    let restored_flags : Array[Byte] = []
    read_u8(root, unsigned, (_, chunk) => {
      for value in chunk {
        restored_flags.push(value)
      }
    })
    assert_eq(restored_flags, flags)
    let empty = write_u8(root, "empty.u8", [0, 3], (_, _) => {
      fail("empty producer must not be called")
    })
    assert_eq(empty.count, 0L)
    assert_eq(empty.byte_length, 0L)
    verify_blob(root, empty)
    read_u8(root, empty, (_, _) => fail("empty reader must not be called"))
    try shape_count([], 8L) catch {
      _ => ()
    } noraise {
      _ => fail("empty-rank shape was accepted")
    }
    try shape_count([-1], 8L) catch {
      _ => ()
    } noraise {
      _ => fail("negative shape was accepted")
    }
    try write_u8(root, "../unsafe", [1], (_, _) => [b'\x00']) catch {
      _ => ()
    } noraise {
      _ => fail("unsafe basename was accepted")
    }
    try verify_blob(root, { ..signed, dtype: "u8", }) catch {
      _ => ()
    } noraise {
      _ => fail("wrong dtype was accepted")
    }
    try verify_blob(root, { ..unsigned, byte_length: 1L, }) catch {
      _ => ()
    } noraise {
      _ => fail("wrong byte length was accepted")
    }
    @fs.write_file(root + "/flags.u8", b"short", create_mode=CreateOrTruncate)
    try verify_blob(root, unsigned) catch {
      _ => ()
    } noraise {
      _ => fail("truncated blob was accepted")
    }
  }
}

///|
async test "shape is frozen before producer callback and replacement symlink is refused" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="moonrobo-checkpoint-shape-")
    group.add_defer(() => @fs.rmdir(root, recursive=true))
    let shape = [1]
    let descriptor = write_f64le(root, "frozen.f64", shape, (_, _) => {
      shape[0] = 2
      [1.25]
    })
    assert_eq(shape, [2])
    assert_eq(descriptor.shape, [1])
    assert_eq(descriptor.count, 1L)
    validate_descriptor(descriptor)
    verify_blob(root, descriptor)
    try write_u8(root, String::make(248, 'a'), [1], (_, _) => [b'\x00']) catch {
      _ => ()
    } noraise {
      _ => fail("basename that exceeds staging filename limit was accepted")
    }
    @fs.rename(root + "/frozen.f64", root + "/saved.f64", replace=false)
    @fs.symlink(target=root + "/saved.f64", root + "/frozen.f64")
    try verify_blob(root, descriptor) catch {
      _ => ()
    } noraise {
      _ => fail("replacement symlink was accepted")
    }
  }
}
