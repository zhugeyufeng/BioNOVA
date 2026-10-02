#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "embedded_script.h"

#ifndef BIONOVA_VERSION
#define BIONOVA_VERSION "dev"
#endif
#ifndef BIONOVA_COMMIT
#define BIONOVA_COMMIT "unknown"
#endif
#ifndef BIONOVA_BUILD_DATE
#define BIONOVA_BUILD_DATE "unknown"
#endif
#ifndef BIONOVA_SCRIPT_SHA256
#define BIONOVA_SCRIPT_SHA256 "unknown"
#endif

/* Absolute path: bionova usually runs as root, so bash must never be resolved through PATH. */
#define BASH_PATH "/bin/bash"
#define SCRIPT_NAME "bioinfo-server-init.sh"

#define MEMFD_UNAVAILABLE (-1)
#define EXEC_FAILED (-2)

static volatile sig_atomic_t child_pid = 0;

static void usage(void) {
    puts("BioNOVA - bioinformatics server bootstrap and user management");
    puts("");
    puts("Usage:");
    puts("  bionova");
    puts("  bionova --dry-run");
    puts("  bionova --version");
    puts("  bionova --script-sha256");
    puts("  bionova --help");
    puts("");
    puts("The executable contains the full bioinfo-server-init.sh workflow.");
    puts("Target platform: Ubuntu 22.04/24.04. Runtime dependency: " BASH_PATH ".");
}

static int write_all(int fd, const unsigned char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

static char **build_child_argv(const char *script_path, int argc, char **argv) {
    char **child_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (child_argv == NULL) return NULL;

    child_argv[0] = "bash";
    child_argv[1] = (char *)script_path;
    for (int i = 1; i < argc; i++) {
        child_argv[i + 1] = argv[i];
    }
    child_argv[argc + 1] = NULL;
    return child_argv;
}

/*
 * Preferred path: keep the script in a sealed anonymous memfd and replace this
 * process with bash. Nothing touches the filesystem, and because no bionova
 * parent remains, Ctrl+C or an SSH hangup reaches bash directly with nothing
 * left behind to clean up. Returns only on failure.
 */
static int exec_from_memfd(int argc, char **argv) {
    char script_path[64];
    char fd_text[16];

    if (access("/proc/self/fd", F_OK) != 0) return MEMFD_UNAVAILABLE;

    int fd = memfd_create(SCRIPT_NAME, MFD_ALLOW_SEALING);
    if (fd < 0) return MEMFD_UNAVAILABLE;

    if (write_all(fd, embedded_script, embedded_script_len) != 0) {
        close(fd);
        return MEMFD_UNAVAILABLE;
    }
    /* Best effort: forbid any further modification of the script contents. */
    (void)fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE | F_SEAL_SEAL);

    snprintf(script_path, sizeof(script_path), "/proc/self/fd/%d", fd);
    snprintf(fd_text, sizeof(fd_text), "%d", fd);

    char **child_argv = build_child_argv(script_path, argc, argv);
    if (child_argv == NULL ||
        setenv("BIONOVA_SCRIPT_FD", fd_text, 1) != 0 ||
        setenv("BIONOVA_NAME", "bionova", 1) != 0) {
        free(child_argv);
        close(fd);
        unsetenv("BIONOVA_SCRIPT_FD");
        return MEMFD_UNAVAILABLE;
    }

    execv(BASH_PATH, child_argv);

    int saved = errno;
    free(child_argv);
    close(fd);
    unsetenv("BIONOVA_SCRIPT_FD");
    errno = saved;
    return EXEC_FAILED;
}

static void forward_signal(int sig) {
    pid_t pid = (pid_t)child_pid;
    if (pid > 0) kill(pid, sig);
}

static void cleanup_tempfile(const char *script_path, const char *tempdir) {
    if (script_path != NULL) unlink(script_path);
    rmdir(tempdir);
}

/* Fallback for kernels or sandboxes without memfd_create or /proc. */
static int run_from_tempfile(int argc, char **argv) {
    char tempdir[] = "/tmp/bionova-XXXXXX";
    if (mkdtemp(tempdir) == NULL) {
        fprintf(stderr, "bionova: mkdtemp failed: %s\n", strerror(errno));
        return 1;
    }

    char script_path[PATH_MAX];
    if (snprintf(script_path, sizeof(script_path), "%s/%s", tempdir, SCRIPT_NAME) >= (int)sizeof(script_path)) {
        fprintf(stderr, "bionova: temp path too long\n");
        cleanup_tempfile(NULL, tempdir);
        return 1;
    }

    int fd = open(script_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0700);
    if (fd < 0) {
        fprintf(stderr, "bionova: create embedded script failed: %s\n", strerror(errno));
        cleanup_tempfile(NULL, tempdir);
        return 1;
    }

    if (write_all(fd, embedded_script, embedded_script_len) != 0) {
        fprintf(stderr, "bionova: write embedded script failed: %s\n", strerror(errno));
        close(fd);
        cleanup_tempfile(script_path, tempdir);
        return 1;
    }
    close(fd);

    char **child_argv = build_child_argv(script_path, argc, argv);
    if (child_argv == NULL || setenv("BIONOVA_NAME", "bionova", 1) != 0) {
        fprintf(stderr, "bionova: out of memory\n");
        free(child_argv);
        cleanup_tempfile(script_path, tempdir);
        return 1;
    }

    /*
     * Like system(3): the terminal delivers SIGINT/SIGQUIT to bash as well, so
     * the parent ignores them and survives to remove the temp file. SIGHUP and
     * SIGTERM may be sent to the parent alone, so they are forwarded to bash.
     */
    struct sigaction ignore_action, forward_action;
    struct sigaction old_int, old_quit, old_hup, old_term;
    memset(&ignore_action, 0, sizeof(ignore_action));
    memset(&forward_action, 0, sizeof(forward_action));
    ignore_action.sa_handler = SIG_IGN;
    sigemptyset(&ignore_action.sa_mask);
    forward_action.sa_handler = forward_signal;
    sigemptyset(&forward_action.sa_mask);

    sigset_t block, old_mask;
    sigemptyset(&block);
    sigaddset(&block, SIGHUP);
    sigaddset(&block, SIGTERM);
    sigprocmask(SIG_BLOCK, &block, &old_mask);

    sigaction(SIGINT, &ignore_action, &old_int);
    sigaction(SIGQUIT, &ignore_action, &old_quit);
    sigaction(SIGHUP, &forward_action, &old_hup);
    sigaction(SIGTERM, &forward_action, &old_term);

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "bionova: fork failed: %s\n", strerror(errno));
        sigprocmask(SIG_SETMASK, &old_mask, NULL);
        free(child_argv);
        cleanup_tempfile(script_path, tempdir);
        return 1;
    }

    if (pid == 0) {
        sigaction(SIGINT, &old_int, NULL);
        sigaction(SIGQUIT, &old_quit, NULL);
        sigaction(SIGHUP, &old_hup, NULL);
        sigaction(SIGTERM, &old_term, NULL);
        sigprocmask(SIG_SETMASK, &old_mask, NULL);
        execv(BASH_PATH, child_argv);
        fprintf(stderr, "bionova: exec %s failed: %s\n", BASH_PATH, strerror(errno));
        _exit(127);
    }

    child_pid = pid;
    sigprocmask(SIG_SETMASK, &old_mask, NULL);

    int status = 0;
    for (;;) {
        if (waitpid(pid, &status, 0) >= 0) break;
        if (errno != EINTR) {
            fprintf(stderr, "bionova: waitpid failed: %s\n", strerror(errno));
            status = 1 << 8;
            break;
        }
    }

    free(child_argv);
    cleanup_tempfile(script_path, tempdir);

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 1;
}

int main(int argc, char **argv) {
    if (argc > 1) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            usage();
            return 0;
        }
        if (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "version") == 0) {
            printf("BioNOVA %s (commit=%s build=%s script_sha256=%s)\n",
                   BIONOVA_VERSION, BIONOVA_COMMIT, BIONOVA_BUILD_DATE, BIONOVA_SCRIPT_SHA256);
            return 0;
        }
        if (strcmp(argv[1], "--script-sha256") == 0) {
            puts(BIONOVA_SCRIPT_SHA256);
            return 0;
        }
    }

    if (access(BASH_PATH, X_OK) != 0) {
        fprintf(stderr, "bionova: %s is required: %s\n", BASH_PATH, strerror(errno));
        return 127;
    }

    if (exec_from_memfd(argc, argv) == EXEC_FAILED) {
        fprintf(stderr, "bionova: exec %s failed: %s\n", BASH_PATH, strerror(errno));
        return 127;
    }
    return run_from_tempfile(argc, argv);
}
