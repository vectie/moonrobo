// Use actual SDK3.1 declarations, implementing only a local fake SDK for this
// executable. It never links the SDK archive/DDS and cannot address a robot.
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
#include <thread>
#include <vector>
#include <highcontroller.h>

namespace {
noetix::RobotHardwareStatusCallback callback;
bool init_result = false, throw_on_publish = false;
int init_calls = 0, subscriptions = 0, publishes = 0;
double last_vertical = 0, last_horizontal = 0;
noetix::ControlCmd last_command = noetix::ControlCmd::DEFAULT;
uint16_t last_data = 0;
}

namespace noetix {
class DDSWrapper {};
HighController::~HighController() = default;
HighController* HighController::Instance() {
  static auto* controller = new HighController;
  return controller;
}
bool HighController::init() { ++init_calls; return init_result; }
void HighController::subscribe_robot_hardware_status(RobotHardwareStatusCallback incoming) {
  assert(init_result);
  ++subscriptions;
  callback = incoming;
}
void HighController::publish_cmd(double x, double z, ControlCmd action, uint16_t data) {
  if (throw_on_publish) throw std::runtime_error("fixture publication failure");
  ++publishes;
  last_vertical = x; last_horizontal = z; last_command = action; last_data = data;
}
}

extern "C" int moonrobo_e1_init(char*, int);
extern "C" int moonrobo_e1_capture(double*, char*, int);
extern "C" int moonrobo_e1_publish(double, double, int, int, char*, int);

int main() {
  assert(std::strcmp(SDK_VERSION, "3.1.0") == 0);
  std::array<double, 173> out;
  out.fill(-1000);
  char error[256]{};
  assert(moonrobo_e1_capture(out.data(), error, sizeof(error)) == -1);
  assert(out[0] == -1000);
  assert(moonrobo_e1_publish(0, 0, 0, 0, error, sizeof(error)) == -1);
  assert(moonrobo_e1_init(error, sizeof(error)) == -1);
  assert(init_calls == 1 && subscriptions == 0);
  init_result = true;
  assert(moonrobo_e1_init(error, sizeof(error)) == 0);
  assert(moonrobo_e1_init(error, sizeof(error)) == 0);
  assert(init_calls == 2 && subscriptions == 1);
  assert(moonrobo_e1_capture(out.data(), error, sizeof(error)) == -1);

  noetix::RobotHardwareStatus status{};
  for (int i = 0; i < 24; ++i) {
    auto& motor = status.motor_data[i];
    motor.motor_id = 100 + i; motor.pos = i + .25; motor.vel = i + .5;
    motor.tau = i + .75; motor.error = i; motor.temperature = 30 + i;
  }
  for (int i = 0; i < 4; ++i) status.imu_data.ori[i] = i + 2;
  for (int i = 0; i < 3; ++i) {
    status.imu_data.angular_vel[i] = i + 6;
    status.imu_data.linear_acc[i] = i + 9;
  }
  for (int i = 0; i < 2; ++i) status.remote_data.axes[i] = i + 12;
  for (int i = 0; i < 14; ++i) status.remote_data.button[i] = i % 2;
  status.workmode = 3;
  callback(status);
  status.motor_data[0].pos = -99; // The adapter must own a copy of the callback.
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  assert(moonrobo_e1_capture(out.data(), error, sizeof(error)) == 0);
  for (int i = 0; i < 24; ++i) {
    assert(out[i * 6] == 100 + i && out[i * 6 + 1] == i + .25);
    assert(out[i * 6 + 2] == i + .5 && out[i * 6 + 3] == i + .75);
    assert(out[i * 6 + 4] == i && out[i * 6 + 5] == 30 + i);
  }
  for (int i = 0; i < 4; ++i) assert(out[144 + i] == i + 2);
  for (int i = 0; i < 3; ++i) {
    assert(out[148 + i] == i + 6 && out[151 + i] == i + 9);
  }
  for (int i = 0; i < 2; ++i) assert(out[154 + i] == i + 12);
  for (int i = 0; i < 14; ++i) assert(out[156 + i] == i % 2);
  assert(out[170] == 3 && out[171] >= 3 && out[172] == -1000);
  for (int code : {0, 4, 12}) {
    assert(moonrobo_e1_publish(.5, -.25, code, 65535, error, sizeof(error)) == 0);
    assert(last_vertical == .5 && last_horizontal == -.25 && last_data == 65535);
    assert(last_command == (code == 0 ? noetix::ControlCmd::WALK :
      code == 4 ? noetix::ControlCmd::RUN : noetix::ControlCmd::DEFAULT));
  }
  assert(static_cast<int>(last_command) == 14 && publishes == 3);
  assert(moonrobo_e1_publish(0, 0, 14, 0, error, sizeof(error)) == -1);
  assert(moonrobo_e1_publish(0, 0, 0, -1, error, sizeof(error)) == -1);
  assert(moonrobo_e1_publish(0, 0, 0, 65536, error, sizeof(error)) == -1);
  assert(moonrobo_e1_publish(std::numeric_limits<double>::infinity(), 0, 0, 0, error, sizeof(error)) == -1);
  throw_on_publish = true;
  assert(moonrobo_e1_publish(0, 0, 0, 0, error, sizeof(error)) == -1);
  assert(std::strstr(error, "fixture publication failure") != nullptr);
  assert(publishes == 3);
  std::cout << "SDK3.1 adapter: actual headers, fake SDK only; callback snapshot/age, 24 motors, IMU/remote/mode, init and publication/error mapping passed\n";
}
