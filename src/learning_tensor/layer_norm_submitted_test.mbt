///|
test "submitted expanded LayerNorm forward backward and two Adam states match" {
  let device = layer_norm_test_device()
  guard layer_norm_test_backend(device) is Some(backend) else { return }
  assert_true(backend.has_layer_norm_submitted())
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
          let label = "submitted rows=\{rows} width=\{width} dtype=\{Repr(dtype)} fixture=\{fixture} step=\{step}"
          let ya = layer_norm_expanded(xa, wa, ba)
          let yb = xb.layer_norm_submitted(wb, bb)
          // Identical ATen order must give identical forward values.
          assert_eq(ya.values(), yb.values())
          ya.mul(coefficients).square().mean().backward()
          yb.mul(coefficients).square().mean().backward()
          layer_norm_near(
            xb.gradient_values(),
            xa.gradient_values(),
            label=label + " input",
          )
          layer_norm_near(
            wb.gradient_values(),
            wa.gradient_values(),
            label=label + " weight",
          )
          layer_norm_near(
            bb.gradient_values(),
            ba.gradient_values(),
            label=label + " bias",
          )
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
    "SUBMITTED_LN_GATE_PASS shapes=3x4,512x2048,2048x2048 dtypes=fp32,fp64 fixtures=ordinary,near-constant,constant updates=2",
  )
}
