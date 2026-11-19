// Optional ABI-2 FK submission. Each statement preserves MoonBit's ATen node
// creation order, including multiply-by-one and add-zero from affine().
// This reduces language-boundary submissions, not CUDA kernel count.
extern "C" void* mr_tensor_axis_angle_submitted_v1(void* angle,
    double x, double y, double z, char* err, int cap) {
  return tensor([&] {
    auto& a = unbox(angle);
    if (a.dim() != 2 || a.size(1) != 1 || a.size(0) <= 0 || a.size(0) > 65536 ||
        !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) ||
        (a.scalar_type() != torch::kFloat32 && a.scalar_type() != torch::kFloat64))
      throw std::invalid_argument("submitted axis-angle requires bounded FP32/FP64 [B,1] and finite axis");
    auto c = a.cos();
    auto s = a.sin();
    auto k = c * -1.0 + 1.0;
    auto affine = [](const torch::Tensor& t, double scale) {
      return t * scale + 0.0;
    };
    auto r0 = affine(k, x*x); r0 = r0 + c;
    auto r1 = affine(k, x*y); auto s1 = affine(s, z); r1 = r1 - s1;
    auto r2 = affine(k, x*z); auto s2 = affine(s, y); r2 = r2 + s2;
    auto r3 = affine(k, y*x); auto s3 = affine(s, z); r3 = r3 + s3;
    auto r4 = affine(k, y*y); r4 = r4 + c;
    auto r5 = affine(k, y*z); auto s5 = affine(s, x); r5 = r5 - s5;
    auto r6 = affine(k, z*x); auto s6 = affine(s, y); r6 = r6 - s6;
    auto r7 = affine(k, z*y); auto s7 = affine(s, x); r7 = r7 + s7;
    auto r8 = affine(k, z*z); r8 = r8 + c;
    return torch::cat({r0,r1,r2,r3,r4,r5,r6,r7,r8},1).reshape({-1,3,3});
  }, err, cap);
}
