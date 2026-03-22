/*
 * native_daemon - A minimal helper that fork/daemonizes and execs the target
 * 
 * This bypasses .NET's problematic fork() semantics by doing all the
 * daemonization in native code before exec'ing nalar.
 * 
 * Usage: native_daemon <path_to_binary> [arg1] [arg2] ...
 * 
 * Exits with:
 *   0 - success (daemon started)
 *   1 - fork failed
 *   2 - setsid failed
 *   3 - daemon failed
 *   4 - exec failed
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <binary> [args...]\n", argv[0]);
        return 1;
    }
    
    char *program = argv[1];
    char **args = &argv[1];  // argv[0] = program name for exec
    
    // Fork
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "fork failed: %s\n", strerror(errno));
        return 1;
    }
    
    if (pid > 0) {
        // Parent - exit immediately, daemon will run independently
        return 0;
    }
    
    // Child process
    
    // Create new session - detaches from controlling terminal
    if (setsid() < 0) {
        fprintf(stderr, "setsid failed: %s\n", strerror(errno));
        return 2;
    }
    
    // Double-fork to prevent acquiring a new controlling terminal
    pid = fork();
    if (pid < 0) {
        return 2;
    }
    if (pid > 0) {
        // First child exits
        return 0;
    }
    
    // Daemonize - change to / and close stdin/stdout/stderr
    if (daemon(1, 1) != 0) {  // nochdir=1, noclose=1 (keep fds, we'll redirect)
        return 3;
    }
    
    // Redirect stdin/stdout/stderr to /dev/null
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > 2) close(fd);
    }
    
    // Exec the target program
    execv(program, args);
    
    // If exec fails, we're still in the daemon - just exit
    return 4;
}
