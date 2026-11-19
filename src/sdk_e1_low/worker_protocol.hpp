#pragma once
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <poll.h>
#include <sys/socket.h>

// Local SOCK_SEQPACKET protocol. Worker and plugin are built and shipped together.
namespace low_ipc {
enum class Op : uint32_t { init, capture, index, publish };
struct Request {
  Op op{};
  char name[128]{};
  std::array<double, 120> commands{};
};
struct Reply {
  int32_t result{}, index{};
  int64_t age_ms{};
  char error[512]{};
  std::array<double, 171> values{};
};

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;
// Five missed 50 Hz updates end a publishing session. Status/name reads
// must never renew the last motor command.
constexpr auto command_lease = 100ms;

inline bool readable_until(int fd, Clock::time_point end) {
  pollfd item{fd, POLLIN, 0};
  for (;;) {
    int timeout = -1;
    if (end != Clock::time_point::max()) {
      const auto left = std::chrono::ceil<std::chrono::milliseconds>(end - Clock::now());
      if (left.count() <= 0) return false;
      timeout = static_cast<int>(left.count());
    }
    int result = poll(&item, 1, timeout);
    if (result >= 0) return result > 0 && (item.revents & POLLIN);
    if (errno != EINTR) return false;
  }
}
template<class T> bool send_record(int fd, const T& record) {
  ssize_t n;
  do { n = send(fd, &record, sizeof record, MSG_NOSIGNAL | MSG_DONTWAIT); }
  while (n < 0 && errno == EINTR);
  return n == sizeof record;
}
template<class T> bool receive(int fd, T& record) {
  ssize_t n;
  do { n = recv(fd, &record, sizeof record, MSG_TRUNC | MSG_DONTWAIT); }
  while (n < 0 && errno == EINTR);
  return n == sizeof record;
}
} // namespace low_ipc
