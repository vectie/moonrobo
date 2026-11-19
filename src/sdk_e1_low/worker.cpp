#include "worker_protocol.hpp"
#include <csignal>
#include <cstdlib>
#include <sys/prctl.h>
#include <unistd.h>

extern "C" {
int moonrobo_e1_low_init(char*, int);
int moonrobo_e1_low_capture(double*, int, int64_t*, char*, int);
int moonrobo_e1_low_joint_index(const char*, int32_t*, char*, int);
int moonrobo_e1_low_publish(const double*, int, char*, int);
}

int main(int argc, char** argv) {
  using namespace low_ipc;
  // This executable requires the private supervisor socket even for init.
  int type = 0;
  socklen_t size = sizeof type;
  if (argc != 2 || getsockopt(STDIN_FILENO, SOL_SOCKET, SO_TYPE, &type, &size)
      || type != SOCK_SEQPACKET || prctl(PR_SET_PDEATHSIG, SIGKILL)
      || getppid() != std::strtol(argv[1], nullptr, 10)) return 2;
  auto deadline = Clock::time_point::max();
  while (readable_until(STDIN_FILENO, deadline)) {
    Request req;
    if (!receive(STDIN_FILENO, req) || Clock::now() >= deadline) break;
    Reply reply;
    switch (req.op) {
      case Op::init:
        reply.result = moonrobo_e1_low_init(reply.error, sizeof reply.error);
        break;
      case Op::capture:
        reply.result = moonrobo_e1_low_capture(reply.values.data(), reply.values.size(),
                                              &reply.age_ms, reply.error, sizeof reply.error);
        break;
      case Op::index:
        req.name[sizeof req.name - 1] = 0;
        reply.result = moonrobo_e1_low_joint_index(req.name, &reply.index, reply.error, sizeof reply.error);
        break;
      case Op::publish:
        reply.result = moonrobo_e1_low_publish(req.commands.data(), req.commands.size(),
                                              reply.error, sizeof reply.error);
        if (!reply.result) deadline = Clock::now() + command_lease;
        break;
      default: _exit(2);
    }
    if (!send_record(STDIN_FILENO, reply)) break;
  }
  // Only this helper owns the vendor singleton. The kernel tears down its
  // threads and DDS sockets together, avoiding the racy vendor destructors.
  _exit(0);
}
