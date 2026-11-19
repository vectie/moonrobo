///|
test "one split preserves strided sections and gradients with unused outputs" {
  guard @env.get_env_var("MOONROBO_TENSOR_LIBRARY") is Some(path) else {
    // The numerical admission runner rejects SKIP; a portable checkout need
    // not have the optional native tensor plugin installed.
    println("SKIP shared split: tensor plugin not configured")
    return
  }
  let backend = @learning_tensor.Backend::open(path)
  for dtype in [@learning_tensor.Float32, @learning_tensor.Float64] {
    let make = () => {
      backend.from_values(
        [70, 5],
        Array::makei(350, i => (i - 111).to_double() * 0.03),
        cuda_device=-1,
        requires_grad=true,
        dtype~,
      )
    }
    let a = make()
    let b = make()
    let x = a.transpose_dims(0, 1)
    let y = b.transpose_dims(0, 1)
    let sizes = [3, 3, 3, 3, 29, 29]
    let parts = y.split_sections(sizes)
    let aa = []
    let bb = []
    let mut start = 0
    for i, size in sizes {
      let expected = x.narrow(1, start, size)
      assert_eq(parts[i].values(), expected.values())
      if i != 2 {
        aa.push(expected.square().sum().affine((i + 1).to_double()))
        bb.push(parts[i].square().sum().affine((i + 1).to_double()))
      }
      start += size
    }
    backend.stack(aa).sum().backward()
    backend.stack(bb).sum().backward()
    assert_eq(a.gradient_values(), b.gradient_values())
    assert_true((Some(y.split_sections([3, 3])) catch { _ => None }) is None)
    assert_true((Some(y.split_sections([0, 70])) catch { _ => None }) is None)
  }
}
