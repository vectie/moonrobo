// Actual SDK3.1 declarations, fake implementation: no vendor archive or DDS.
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <lowcontroller.h>

namespace {
noetix::RobotHardwareStatusCallback callback;
bool init_result = true, throw_publish = false;
int initialized = 0, subscribed = 0, published = 0;
int policy_status = 0;

void emit() {
  noetix::RobotHardwareStatus status{};
  for (int i = 0; i < 24; ++i) {
    auto& m = status.motor_data[i];
    m.motor_id = 100 + i; m.pos = i + .25; m.vel = i + .5;
    m.tau = i + .75; m.error = policy_status ? 0 : i; m.temperature = 30 + i;
  }
  if (policy_status == 2) status.motor_data[0].motor_id = 999;
  if (policy_status == 3) status.motor_data[5].error = 1;
  for (int i = 0; i < 4; ++i) status.imu_data.ori[i] = i + 2;
  for (int i = 0; i < 3; ++i) {
    status.imu_data.angular_vel[i] = i + 6;
    status.imu_data.linear_acc[i] = i + 9;
  }
  for (int i = 0; i < 2; ++i) status.remote_data.axes[i] = i + 12;
  for (int i = 0; i < 14; ++i) status.remote_data.button[i] = i % 2;
  status.workmode = 3;
  callback(status);
  status.motor_data[0].pos = -999; // A snapshot must not retain this reference.
}
}

namespace noetix {
class DDSWrapper {};
LowController::~LowController() = default;
LowController* LowController::Instance() {
  static auto* controller = new LowController;
  return controller;
}
bool LowController::init() { ++initialized; return init_result; }
void LowController::subscribe_robot_hardware_status(RobotHardwareStatusCallback incoming) {
  ++subscribed; callback = incoming;
}
int LowController::getJointsIndex(const std::string name) {
  if (name == "fixture_emit") { emit(); return 0; }
  if (name == "fixture_publish_count") return published;
  if (name == "fixture_throw_publish") { throw_publish = true; return 0; }
  if (name == "fixture_resume_publish") { throw_publish = false; return 0; }
  if (name == "fixture_policy_clean") { policy_status = 1; emit(); return 0; }
  if (name == "fixture_policy_wrong_id") { policy_status = 2; emit(); return 0; }
  if (name == "fixture_policy_error") { policy_status = 3; emit(); return 0; }
  if (name.rfind("fixture_slot_", 0) == 0) return std::stoi(name.substr(13));
  return name == "arm_l1_joint" ? 7 : -1;
}
void LowController::set_joint(std::array<MotorCmd, 24> commands) {
  if (throw_publish) throw std::runtime_error("fixture motor publication failure");
  for (int i = 0; i < 24; ++i) {
    const auto& m = commands[i];
    assert(m.motor_id == i);
    if (!policy_status) {
      assert(m.pos == i + .25 && m.vel == i + .5);
      assert(m.tau == i + .75 && m.kp == 10 + i && m.kd == 1 + i);
    } else if (i == 0) {
      assert(m.pos == 100 && m.vel == 10 && m.tau == 20 && m.kp == 30 && m.kd == 40);
    } else {
      const int actor = 23 - i;
      const int direction = actor % 2 == 0 ? -1 : 1;
      assert(m.pos == .25 + direction * (actor + 1) && m.vel == 0 && m.tau == 0);
      assert(m.kp == 10 + actor && m.kd == 1 + actor);
    }
  }
  ++published;
}
}

#ifdef MOONROBO_LOW_FIXTURE_MAIN
extern "C" int moonrobo_e1_low_init(char*, int);
extern "C" int moonrobo_e1_low_capture(double*, int, int64_t*, char*, int);
extern "C" int moonrobo_e1_low_joint_index(const char*, int32_t*, char*, int);
extern "C" int moonrobo_e1_low_publish(const double*, int, char*, int);
int main() {
  assert(std::strcmp(SDK_VERSION, "3.1.0") == 0);
  char error[256]{};
  std::array<double, 172> values{};
  int64_t age = -1;
  int32_t index = -1;
  assert(moonrobo_e1_low_capture(values.data(), 171, &age, error, sizeof(error)) == -1);
  init_result = false;
  assert(moonrobo_e1_low_init(error, sizeof(error)) == -1);
  init_result = true;
  assert(moonrobo_e1_low_init(error, sizeof(error)) == 0);
  assert(moonrobo_e1_low_init(error, sizeof(error)) == 0);
  assert(initialized == 2 && subscribed == 1);
  assert(moonrobo_e1_low_joint_index("missing", &index, error, sizeof(error)) == -1);
  assert(moonrobo_e1_low_joint_index("fixture_emit", &index, error, sizeof(error)) == 0);
  assert(moonrobo_e1_low_capture(values.data(), 170, &age, error, sizeof(error)) == -1);
  assert(moonrobo_e1_low_capture(values.data(), 171, &age, error, sizeof(error)) == 0);
  assert(values[1] == .25 && values[170] == 3 && values[171] == 0 && age >= 0);
  std::array<double, 120> commands{};
  for (int i = 0; i < 24; ++i) {
    commands[i * 5] = i + .25; commands[i * 5 + 1] = i + .5;
    commands[i * 5 + 2] = i + .75; commands[i * 5 + 3] = 10 + i;
    commands[i * 5 + 4] = 1 + i;
  }
  assert(moonrobo_e1_low_publish(commands.data(), 119, error, sizeof(error)) == -1);
  assert(moonrobo_e1_low_publish(commands.data(), 120, error, sizeof(error)) == 0);
  commands[3] = -1;
  assert(moonrobo_e1_low_publish(commands.data(), 120, error, sizeof(error)) == -1);
  commands[3] = std::numeric_limits<double>::infinity();
  assert(moonrobo_e1_low_publish(commands.data(), 120, error, sizeof(error)) == -1);
  assert(published == 1);
  std::cout << "SDK3.1 low C++ ABI: actual headers/fake SDK, callback state, dimensions, names and complete command validation passed\n";
}
#endif
