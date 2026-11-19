///|
test "fused LN pointwise SiLU tail preserves reductions gradients and two Adam states" {
  let device = layer_norm_test_device()
  guard device >= 0 else {
    println("SKIP fused tail CUDA gate: explicit device required")
    return
  }
  guard layer_norm_test_backend(device) is Some(backend) else {
    fail("CUDA backend required")
  }
  assert_true(backend.has_ln_silu_tail())
  for (rows, width) in [(3, 4), (512, 2048), (2048, 2048)] {
    for dtype in [@learning_tensor.Float32, @learning_tensor.Float64] {
      for fixture in 0..<3 {
        let values = Array::makei(rows * width, i => {
          match fixture {
            0 => ((i * 7 + i / width) % 31 - 15).to_double() * 0.07
            1 => 1.0 + (i % 7 - 3).to_double() * 0.0001
            _ => 0.25
          }
        })
        let make = (shape, data, grad) => {
          backend.from_values(
            shape,
            data,
            cuda_device=device,
            requires_grad=grad,
            dtype~,
          )
        }
        let xa = make([rows, width], values, true)
        let xb = make([rows, width], values, true)
        let weights = Array::makei(width, i => (i % 7 - 3).to_double() * 0.2)
        let wa = make([width], weights, true)
        let wb = make([width], weights, true)
        let ba = make([width], Array::make(width, 0.1), true)
        let bb = make([width], Array::make(width, 0.1), true)
        let oa = backend.adam([wa, ba], learning_rate=0.0002)
        let ob = backend.adam([wb, bb], learning_rate=0.0002)
        let coefficients = make(
          [rows, width],
          Array::makei(rows * width, i => (i % 13 - 6).to_double() * 0.11),
          false,
        )
        for step in 0..<2 {
          let label = "fused-tail rows=\{rows} dtype=\{Repr(dtype)} fixture=\{fixture} step=\{step}"
          let ya = layer_norm_expanded(xa, wa, ba).silu()
          let centered = xb.sub(xb.mean_dim(-1, keepdim=true))
          let yb = centered.ln_silu_tail(
            centered.square().mean_dim(-1, keepdim=true),
            wb,
            bb,
          )
          layer_norm_near(yb.values(), ya.values(), label=label + " forward")
          ya.mul(coefficients).square().mean().backward()
          yb.mul(coefficients).square().mean().backward()
          for (a, b) in [(xa, xb), (wa, wb), (ba, bb)] {
            layer_norm_near(
              b.gradient_values(),
              a.gradient_values(),
              label=label + " gradient",
            )
          }
          oa.step(clip_norm=1.0)
          ob.step(clip_norm=1.0)
          assert_eq(oa.audit_metadata(), ob.audit_metadata())
          for p in 0..<2 {
            for kind in 0..<3 {
              layer_norm_near(
                ob.audit_tensor(p, kind~).values(),
                oa.audit_tensor(p, kind~).values(),
                label=label + " Adam \{p}/\{kind}",
              )
            }
          }
          oa.zero_grad()
          ob.zero_grad()
          xa.zero_gradient()
          xb.zero_gradient()
        }
      }
    }
  }
  println(
    "FUSED_LN_TAIL_GATE_PASS shapes=3x4,512x2048,2048x2048 dtypes=fp32,fp64 fixtures=ordinary,near-constant,constant updates=2",
  )
}
