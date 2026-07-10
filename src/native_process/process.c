#include "moonbit.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

static char g_last_error[512] = "";

static void moonrobo_process_set_error(const char *message) {
  snprintf(g_last_error, sizeof(g_last_error), "%s", message ? message : "");
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moonrobo_process_last_error(void) {
  int32_t len = (int32_t)strlen(g_last_error);
  moonbit_bytes_t out = moonbit_make_bytes(len, 0);
  if (len > 0) {
    memcpy(out, g_last_error, (size_t)len);
  }
  return out;
}

MOONBIT_FFI_EXPORT int32_t moonrobo_process_start_shell_script(const char *script_path) {
  moonrobo_process_set_error("");
  if (!script_path || script_path[0] == '\0') {
    moonrobo_process_set_error("script path is empty");
    return -1;
  }
#if defined(_WIN32)
  char cmdline[4096];
  snprintf(cmdline, sizeof(cmdline), "cmd /C sh \"%s\"", script_path);
  STARTUPINFOA startup;
  PROCESS_INFORMATION process;
  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  ZeroMemory(&process, sizeof(process));
  if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, CREATE_NEW_PROCESS_GROUP, NULL, NULL, &startup, &process)) {
    moonrobo_process_set_error("CreateProcess failed");
    return -1;
  }
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return (int32_t)process.dwProcessId;
#else
  pid_t pid = fork();
  if (pid < 0) {
    moonrobo_process_set_error("fork failed");
    return -1;
  }
  if (pid == 0) {
    setsid();
    execlp("sh", "sh", script_path, (char *)NULL);
    _exit(127);
  }
  return (int32_t)pid;
#endif
}

MOONBIT_FFI_EXPORT int32_t moonrobo_process_run_shell_script(const char *script_path) {
  moonrobo_process_set_error("");
  if (!script_path || script_path[0] == '\0') {
    moonrobo_process_set_error("script path is empty");
    return -1;
  }
#if defined(_WIN32)
  char cmdline[4096];
  snprintf(cmdline, sizeof(cmdline), "cmd /C sh \"%s\"", script_path);
  STARTUPINFOA startup;
  PROCESS_INFORMATION process;
  ZeroMemory(&startup, sizeof(startup));
  startup.cb = sizeof(startup);
  ZeroMemory(&process, sizeof(process));
  if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
    moonrobo_process_set_error("CreateProcess failed");
    return -1;
  }
  CloseHandle(process.hThread);
  if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0) {
    CloseHandle(process.hProcess);
    moonrobo_process_set_error("process wait failed");
    return -1;
  }
  DWORD exit_code = 0;
  if (!GetExitCodeProcess(process.hProcess, &exit_code)) {
    CloseHandle(process.hProcess);
    moonrobo_process_set_error("failed to read process exit code");
    return -1;
  }
  CloseHandle(process.hProcess);
  return (int32_t)exit_code;
#else
  pid_t pid = fork();
  if (pid < 0) {
    moonrobo_process_set_error("fork failed");
    return -1;
  }
  if (pid == 0) {
    execlp("sh", "sh", script_path, (char *)NULL);
    _exit(127);
  }
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) {
    if (errno != EINTR) {
      moonrobo_process_set_error("waitpid failed");
      return -1;
    }
  }
  if (WIFEXITED(status)) {
    return (int32_t)WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    return (int32_t)(128 + WTERMSIG(status));
  }
  moonrobo_process_set_error("process ended without an exit status");
  return -1;
#endif
}

MOONBIT_FFI_EXPORT int32_t moonrobo_process_is_running(int32_t pid) {
  if (pid <= 0) {
    return 0;
  }
#if defined(_WIN32)
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
  if (!process) {
    return 0;
  }
  DWORD code = 0;
  int32_t running = 0;
  if (GetExitCodeProcess(process, &code)) {
    running = code == STILL_ACTIVE ? 1 : 0;
  }
  CloseHandle(process);
  return running;
#else
  if (kill((pid_t)pid, 0) == 0) {
    return 1;
  }
  return 0;
#endif
}

MOONBIT_FFI_EXPORT int32_t moonrobo_process_stop(int32_t pid) {
  moonrobo_process_set_error("");
  if (pid <= 0) {
    moonrobo_process_set_error("pid must be positive");
    return -1;
  }
#if defined(_WIN32)
  HANDLE process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD)pid);
  if (!process) {
    return 0;
  }
  DWORD code = 0;
  if (GetExitCodeProcess(process, &code) && code != STILL_ACTIVE) {
    CloseHandle(process);
    return 0;
  }
  if (!TerminateProcess(process, 0)) {
    CloseHandle(process);
    moonrobo_process_set_error("TerminateProcess failed");
    return -1;
  }
  CloseHandle(process);
  return 1;
#else
  if (kill((pid_t)pid, SIGTERM) == 0) {
    return 1;
  }
  if (errno == ESRCH) {
    return 0;
  }
  moonrobo_process_set_error("kill failed");
  return -1;
#endif
}
