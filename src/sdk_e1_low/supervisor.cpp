#include "worker_protocol.hpp"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <mutex>
#include <signal.h>
#include <spawn.h>
#include <stdexcept>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

extern char** environ;
namespace {
using namespace low_ipc;

std::string worker_path() {
  Dl_info info{};
  if (!dladdr(reinterpret_cast<void*>(&worker_path), &info))
    throw std::runtime_error("cannot locate the low SDK plugin");
  return std::filesystem::canonical(info.dli_fname).parent_path() / "moonrobo_e1_low_worker_v1";
}

struct Session {
  std::mutex mutex;
  int fd = -1;
  pid_t pid = -1;
  pid_t owner = getpid();
  unsigned clients = 0;

  void spawn_worker() {
    const auto path = worker_path(), parent = std::to_string(owner);
    char* argv[] = {const_cast<char*>(path.c_str()), const_cast<char*>(parent.c_str()), nullptr};
    int ends[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, ends))
      throw std::runtime_error("cannot create low SDK control socket");
    posix_spawn_file_actions_t actions;
    int err = posix_spawn_file_actions_init(&actions);
    if (!err) {
      err = posix_spawn_file_actions_adddup2(&actions, ends[1], STDIN_FILENO);
      if (!err) err = posix_spawn(&pid, path.c_str(), &actions, nullptr, argv, environ);
      posix_spawn_file_actions_destroy(&actions);
    }
    close(ends[1]);
    if (err) {
      close(ends[0]);
      pid = -1;
      throw std::runtime_error(std::string("start low SDK worker: ") + std::strerror(err));
    }
    fd = ends[0];
  }

  bool stop() {
    if (fd >= 0) {
      shutdown(fd, SHUT_RDWR);
      close(fd);
      fd = -1;
    }
    if (pid < 0) return true;
    int status{};
    const auto deadline = Clock::now() + 250ms;
    for (;;) {
      const pid_t done = waitpid(pid, &status, WNOHANG);
      if (done == pid) {
        pid = -1;
        return WIFEXITED(status) && WEXITSTATUS(status) == 0;
      }
      if (done < 0 && errno != EINTR) { pid = -1; return false; }
      if (Clock::now() >= deadline) break;
      std::this_thread::sleep_for(1ms);
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    pid = -1;
    return false;
  }
  ~Session() {
    if (owner == getpid()) {
      std::lock_guard<std::mutex> lock(mutex);
      stop();
    }
  }

  Reply exchange(const Request& request) {
    if (fd < 0) throw std::runtime_error("low SDK session is closed");
    Reply reply;
    const auto timeout = request.op == Op::init ? 15s : 1s;
    if (!send_record(fd, request) || !readable_until(fd, Clock::now() + timeout) || !receive(fd, reply)) {
      stop();
      throw std::runtime_error("low SDK worker lost, timed out, or command lease expired; session ended");
    }
    if (reply.result) throw std::runtime_error(reply.error);
    return reply;
  }
};

Session& session() { static Session s; return s; }

template <class F> int checked(char* error, int capacity, F fn) {
  try {
    Session& s = session();
    if (s.owner != getpid()) throw std::runtime_error("low SDK session belongs to parent process");
    std::lock_guard<std::mutex> lock(s.mutex);
    fn(s);
    return 0;
  } catch (const std::exception& e) {
    std::snprintf(error, capacity, "%s", e.what());
    return -1;
  } catch (...) {
    std::snprintf(error, capacity, "low SDK supervisor exception");
    return -1;
  }
}
} // namespace

extern "C" int moonrobo_e1_low_init(char* error, int n) {
  return checked(error, n, [](Session& s) {
    if (!s.clients) s.spawn_worker();
    try { s.exchange({Op::init}); }
    catch (...) { s.stop(); throw; }
    ++s.clients;
  });
}
extern "C" int moonrobo_e1_low_shutdown(char* error, int n) {
  return checked(error, n, [](Session& s) {
    if (s.clients && !--s.clients && !s.stop())
      throw std::runtime_error("low SDK worker required forced shutdown or exited abnormally");
  });
}
extern "C" int moonrobo_e1_low_capture(double* values, int count, int64_t* age, char* error, int n) {
  return checked(error, n, [&](Session& s) {
    if (count != 171) throw std::runtime_error("low status requires 171 values");
    auto reply = s.exchange({Op::capture});
    std::copy(reply.values.begin(), reply.values.end(), values);
    *age = reply.age_ms;
  });
}
extern "C" int moonrobo_e1_low_joint_index(const char* name, int32_t* index, char* error, int n) {
  return checked(error, n, [&](Session& s) {
    Request req{Op::index};
    if (std::strlen(name) >= sizeof req.name) throw std::runtime_error("joint name too long");
    std::strcpy(req.name, name);
    *index = s.exchange(req).index;
  });
}
extern "C" int moonrobo_e1_low_publish(const double* values, int count, char* error, int n) {
  return checked(error, n, [&](Session& s) {
    Request req{Op::publish};
    if (count != static_cast<int>(req.commands.size()))
      throw std::runtime_error("low command requires 24 complete motor entries");
    std::copy_n(values, count, req.commands.begin());
    s.exchange(req);
  });
}
