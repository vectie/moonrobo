// SDK3.1 plugin, separate from MoonBit's SDK-free loader stub.
#include "../sdk_e1_native/sdk_v31_state.hpp"
#include <lowcontroller.h>

namespace {
SdkV31State& snapshot() {
  static auto* state = new SdkV31State; // Same lifetime as SDK callbacks/module.
  return *state;
}
}

extern "C" int moonrobo_e1_low_init(char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [] {
    auto& s = snapshot();
    std::lock_guard<std::mutex> lock(s.lifecycle);
    if (s.initialized) return;
    auto* c = noetix::LowController::Instance();
    if (!c->init()) throw std::runtime_error("LowController::init returned false");
    c->subscribe_robot_hardware_status([](const noetix::RobotHardwareStatus& status) {
      snapshot().receive(status);
    });
    s.initialized = true;
  });
}

extern "C" int moonrobo_e1_low_capture(double* out, int count, int64_t* age_ms,
                                      char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [=] {
    if (count != 171) throw std::runtime_error("low status requires 171 values");
    snapshot().capture(out, age_ms);
  });
}

extern "C" int moonrobo_e1_low_joint_index(const char* name, int32_t* out,
                                          char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [=] {
    auto& s = snapshot();
    std::lock_guard<std::mutex> lock(s.lifecycle);
    if (!s.initialized) throw std::runtime_error("low adapter is not initialized");
    const int index = noetix::LowController::Instance()->getJointsIndex(name);
    if (index < 0 || index >= 24) throw std::runtime_error("SDK joint name has no 24-slot index");
    *out = index;
  });
}

extern "C" int moonrobo_e1_low_publish(const double* values, int count,
                                      char* error, int capacity) {
  return sdk_v31_checked(error, capacity, [=] {
    if (count != 120) throw std::runtime_error("low command requires 24 complete motor entries");
    std::array<noetix::MotorCmd, 24> commands{};
    for (int i = 0; i < 24; ++i) {
      const double* row = values + i * 5;
      for (int j = 0; j < 5; ++j)
        if (!std::isfinite(row[j])) throw std::runtime_error("nonfinite motor command");
      if (row[3] < 0 || row[4] < 0) throw std::runtime_error("negative motor gain");
      auto& m = commands[i];
      m.pos = row[0]; m.vel = row[1]; m.tau = row[2]; m.kp = row[3]; m.kd = row[4];
      m.motor_id = i; // SDK3.1 example uses SDK slot numbers as command IDs.
    }
    auto& s = snapshot();
    std::lock_guard<std::mutex> lock(s.lifecycle);
    if (!s.initialized) throw std::runtime_error("low adapter is not initialized");
    noetix::LowController::Instance()->set_joint(commands);
  });
}
