// Minimal PTY shim for MiAgent Desktop.
//
// Odin's POSIX bindings don't expose forkpty(3), and the structs involved
// (termios, winsize) are platform-specific. Keeping the handful of calls we
// need here means the Odin side only deals with an int fd and a pid.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pty.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

// Spawn a login shell attached to a new PTY.
// Returns 0 on success and writes the master fd / child pid to out_fd/out_pid.
// On failure returns -1 and writes a message into err.
int mi_pty_spawn(const char *shell, const char *cwd,
                 unsigned short cols, unsigned short rows,
                 int *out_fd, int *out_pid, char *err, int errlen) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = cols;
  ws.ws_row = rows;

  // Do everything that might allocate or lock before forkpty(): after a fork
  // in a threaded process only async-signal-safe calls are portable, and this
  // app links Mesa/GLFW which do start threads.
  const char *sh = (shell && shell[0]) ? shell : "/bin/sh";
  const char *base = strrchr(sh, '/');
  base = base ? base + 1 : sh;
  char argv0[256];
  snprintf(argv0, sizeof(argv0), "-%s", base);

  setenv("TERM", "xterm-256color", 1);
  setenv("COLORTERM", "truecolor", 1);
  setenv("TERM_PROGRAM", "MiAgentDesktop", 1);
  unsetenv("LINES");
  unsetenv("COLUMNS");

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) {
    if (err && errlen > 0) snprintf(err, (size_t)errlen, "forkpty: %s", strerror(errno));
    return -1;
  }

  if (pid == 0) {
    // Child: forkpty() already made us a session leader with the slave as
    // stdin/stdout/stderr. Keep this to async-signal-safe calls.
    if (cwd && cwd[0]) {
      if (chdir(cwd) != 0) chdir("/");
    }
    execl(sh, argv0, (char *)NULL);
    execl(sh, sh, (char *)NULL);
    _exit(127);
  }

  int flags = fcntl(master, F_GETFL, 0);
  fcntl(master, F_SETFL, flags | O_NONBLOCK);
  fcntl(master, F_SETFD, FD_CLOEXEC);

  *out_fd = master;
  *out_pid = (int)pid;
  return 0;
}

int mi_pty_resize(int fd, unsigned short cols, unsigned short rows) {
  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = cols;
  ws.ws_row = rows;
  return ioctl(fd, TIOCSWINSZ, &ws);
}

// Read available bytes. Returns >0 bytes read, 0 if nothing is available,
// -1 if the pty is gone.
int mi_pty_read(int fd, void *buf, int cap) {
  for (;;) {
    ssize_t n = read(fd, buf, (size_t)cap);
    if (n >= 0) return (int)n;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1;
  }
}

int mi_pty_write(int fd, const void *buf, int len) {
  const char *p = (const char *)buf;
  int left = len;
  while (left > 0) {
    ssize_t n = write(fd, p, (size_t)left);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) return len - left;
      return -1;
    }
    p += n;
    left -= (int)n;
  }
  return len;
}

void mi_pty_terminate(int fd, int pid) {
  if (pid > 0) {
    kill(-pid, SIGHUP);
    kill(pid, SIGHUP);
    kill(-pid, SIGCONT);
  }
  if (fd >= 0) close(fd);
}

// Reap a child that already exited, without blocking.
int mi_pty_reap(int pid) {
  int status = 0;
  if (pid <= 0) return -1;
  pid_t r = waitpid(pid, &status, WNOHANG);
  if (r <= 0) return 0;
  if (WIFEXITED(status)) return WEXITSTATUS(status) + 1;
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
