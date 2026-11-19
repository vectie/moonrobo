// Optional ABI-2 Adam preflight. Include after Adam and mr_adam_step.
// Keep the original route unchanged. This is the same ordered p=2 norm and
// coefficient arithmetic as LibTorch's C++ clip_grad_norm_, with one normal-path
// host read instead of a separate finite-mask read followed by the norm read.
extern "C" int mr_adam_step_checked_norm_v1(
    void *p, double max_norm, double max_value, char *err, int cap) {
  // Without norm clipping there is no finite L2 certificate to reuse.
  if (max_norm == 0.0) return mr_adam_step(p, max_norm, max_value, err, cap);
  return status([&] {
    auto &a = adam(p);
    if (!std::isfinite(max_norm) || max_norm < 0 ||
        !std::isfinite(max_value) || max_value < 0)
      throw std::invalid_argument("invalid gradient clipping limit");
    // Validate the full list before even constructing norm operations. A later
    // missing gradient must not leave earlier gradients or optimizer state changed.
    for (const auto &parameter : a.parameters)
      if (!parameter.grad().defined())
        throw std::invalid_argument("missing Adam gradient; no parameters updated");
    std::vector<torch::Tensor> norms;
    norms.reserve(a.parameters.size());
    for (const auto &parameter : a.parameters)
      norms.emplace_back(parameter.grad().data().norm(2.0));
    auto total_norm_tensor = norms.size() == 1
        ? norms[0] : torch::stack(norms).norm(2.0);
    const double total_norm = total_norm_tensor.item().toDouble();
    if (!std::isfinite(total_norm)) {
      // An infinite L2 norm can also be overflow from entirely finite gradients.
      // Preserve the original distinction and reject both before any mutation.
      // Extra masks/readback occur only on this failure path.
      std::vector<torch::Tensor> finite;
      finite.reserve(a.parameters.size());
      for (const auto &parameter : a.parameters)
        finite.push_back(torch::isfinite(parameter.grad()).all());
      if (!torch::stack(finite).all().item<bool>())
        throw std::invalid_argument("nonfinite Adam gradient; no parameters updated");
      TORCH_CHECK(std::isfinite(total_norm),
          "The total norm of order ", 2.0,
          " for gradients from `parameters` ",
          "is non-finite, so it cannot be clipped. To disable this error and scale ",
          "the gradients with the non-finite norm anyway, set ",
          "`error_if_nonfinite=false`");
    }
    // Reuse the original device/dtype norm, not the host double. This retains
    // rounding, epsilon, norm-then-value order, and each parameter's Adam state.
    auto coefficient = max_norm / (total_norm_tensor + 1e-6);
    auto clamped = torch::clamp(coefficient, std::nullopt, 1.0);
    for (auto &parameter : a.parameters) parameter.grad().data().mul_(clamped);
    if (max_value > 0) torch::nn::utils::clip_grad_value_(a.parameters, max_value);
    a.optimizer->step();
  }, err, cap);
}
