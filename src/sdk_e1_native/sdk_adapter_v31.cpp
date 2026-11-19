// SDK3.1 callback API. Compile against the actual SDK headers/library, never as
// a MoonBit stub. The C ABI retains MoonRobo's existing logical command codes.
#include "sdk_v31_state.hpp"
#include <highcontroller.h>

namespace {
SdkV31State& snapshot() {
  // SDK singletons own background threads without an unsubscribe/shutdown API.
  // The existing loader retains this module for process life. Its callback
  // state must therefore have that same lifetime, rather than static teardown.
  static auto* state = new SdkV31State;
  return *state;
}

}  // namespace

extern "C" int moonrobo_e1_init(char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [] {
    auto& state = snapshot();
    std::lock_guard<std::mutex> lifecycle(state.lifecycle);
    if (state.initialized) return;
    auto* controller = noetix::HighController::Instance();
    if (!controller->init()) throw std::runtime_error("HighController::init returned false");
    // The SDK example initializes its DDS wrapper before subscribing.
    controller->subscribe_robot_hardware_status([](const noetix::RobotHardwareStatus& status) {
      snapshot().receive(status);
    });
    state.initialized = true;
  });
}

extern "C" int moonrobo_e1_capture(double* out, char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [out] {
    int64_t age;
    snapshot().capture(out, &age);
    out[171] = std::min<int64_t>(age, std::numeric_limits<int>::max());
  });
}

extern "C" int moonrobo_e1_publish(double vertical, double horizontal, int action,
                                  int data, char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [=] {
    if (!std::isfinite(vertical) || !std::isfinite(horizontal) || data < 0 || data > 65535)
      throw std::runtime_error("invalid movement or publication data");
    noetix::ControlCmd command;
    switch (action) {
      case 0: command = noetix::ControlCmd::WALK; break;
      case 4: command = noetix::ControlCmd::RUN; break;
      //12 is the existing MoonRobo ABI code, not SDK3.1's raw DEFAULT value14.
      case 12: command = noetix::ControlCmd::DEFAULT; break;
      default: throw std::runtime_error("unsupported action");
    }
    auto& state = snapshot();
    std::lock_guard<std::mutex> lifecycle(state.lifecycle);
    if (!state.initialized) throw std::runtime_error("SDK3.1 adapter is not initialized");
    noetix::HighController::Instance()->publish_cmd(vertical, horizontal, command, static_cast<uint16_t>(data));
  });
}
