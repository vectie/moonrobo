#pragma once
// Private callback state/record codec. No MoonBit objects cross SDK callbacks.
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>
#include <common.h>

namespace {
struct SdkV31State {
  using Clock = std::chrono::steady_clock;
  std::mutex lifecycle, mutex;
  noetix::RobotHardwareStatus status{};
  Clock::time_point received_at{};
  bool received = false, initialized = false;

  void receive(const noetix::RobotHardwareStatus& incoming) {
    std::lock_guard<std::mutex> lock(mutex);
    status = incoming; received_at = Clock::now(); received = true;
  }

  void capture(double* out, int64_t* age_ms) {
    noetix::RobotHardwareStatus copy;
    Clock::time_point receipt;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (!received) throw std::runtime_error("SDK3.1 has not delivered hardware status");
      copy = status; receipt = received_at;
    }
    for (int i = 0; i < 24; ++i) {
      const auto& m = copy.motor_data[i];
      out[i * 6] = m.motor_id; out[i * 6 + 1] = m.pos;
      out[i * 6 + 2] = m.vel; out[i * 6 + 3] = m.tau;
      out[i * 6 + 4] = m.error; out[i * 6 + 5] = m.temperature;
    }
    for (int i = 0; i < 4; ++i) out[144 + i] = copy.imu_data.ori[i];
    for (int i = 0; i < 3; ++i) {
      out[148 + i] = copy.imu_data.angular_vel[i];
      out[151 + i] = copy.imu_data.linear_acc[i];
    }
    for (int i = 0; i < 2; ++i) out[154 + i] = copy.remote_data.axes[i];
    for (int i = 0; i < 14; ++i) out[156 + i] = copy.remote_data.button[i];
    out[170] = copy.workmode;
    *age_ms = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - receipt).count();
  }
};

template <class Operation>
int sdk_v31_checked(char* error, int capacity, Operation operation) {
  try { operation(); return 0; }
  catch (const std::exception& e) { std::snprintf(error, capacity, "%s", e.what()); }
  catch (...) { std::snprintf(error, capacity, "SDK3.1 adapter exception"); }
  return -1;
}
} // namespace
