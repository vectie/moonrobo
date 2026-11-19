// Optional object for the MoonRobo LibTorch plugin. Link against this same
// environment's libtorch_python and libpython; the regular backend has no Python dependency.
#include <Python.h>
#include <torch/torch.h>
#include <torch/csrc/autograd/python_variable.h>
#include <pybind11/pybind11.h>
#include <cstdio>
#include <memory>

namespace py = pybind11;

struct Simulator {
  py::object env;
};

extern "C" void *mr_mjlab_open_v1(const char *config, char *err, int cap) {
  try {
    if (!Py_IsInitialized()) {
      const char *python = std::getenv("MOONROBO_MJLAB_PYTHON");
      if (!python || !*python) throw std::invalid_argument("set MOONROBO_MJLAB_PYTHON to the physics venv executable");
      PyConfig cfg;
      PyConfig_InitPythonConfig(&cfg);
      PyStatus result = PyConfig_SetBytesString(&cfg, &cfg.program_name, python);
      if (!PyStatus_Exception(result)) result = Py_InitializeFromConfig(&cfg);
      if (PyStatus_Exception(result)) {
        std::string reason = result.err_msg ? result.err_msg : "Python initialization failed";
        PyConfig_Clear(&cfg);
        throw std::runtime_error(reason);
      }
      PyConfig_Clear(&cfg);
      PyEval_SaveThread();
    }
    py::gil_scoped_acquire gil;
    try {
      auto module = py::module_::import("moonrobo_mjlab");
      return new Simulator{module.attr("Physics")(config)};
    } catch (const py::error_already_set &e) {
      std::snprintf(err, cap, "%s", e.what());
    }
  } catch (const std::exception &e) {
    std::snprintf(err, cap, "%s", e.what());
  }
  return nullptr;
}

extern "C" void mr_mjlab_close_v1(void *ptr) {
  if (!ptr) return;
  py::gil_scoped_acquire gil;
  std::unique_ptr<Simulator> sim(static_cast<Simulator *>(ptr));
  try {
    sim->env.attr("close")();
  } catch (const py::error_already_set &e) {
    std::fprintf(stderr, "mjlab close: %s\n", e.what());
  }
}

extern "C" void *mr_mjlab_exchange_v1(void *ptr, int op, void *arg, char *err, int cap) {
  py::gil_scoped_acquire gil;
  try {
    auto &env = static_cast<Simulator *>(ptr)->env;
    py::object input = arg ? py::reinterpret_steal<py::object>(
        THPVariable_Wrap(*static_cast<at::Tensor *>(arg))) : py::none();
    py::object result = env.attr("exchange")(op, input);
    if (!THPVariable_Check(result.ptr())) throw std::runtime_error("mjlab returned a non-tensor");
    return new at::Tensor(THPVariable_Unpack(result.ptr()));
  } catch (const std::exception &e) {
    std::snprintf(err, cap, "%s", e.what());
    return nullptr;
  }
}
