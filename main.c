#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
    puts("Target platform: Ubuntu 22.04/24.04. Runtime dependency: bash.");
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

static int run_embedded(int argc, char **argv) {
    char tempdir[] = "/tmp/bionova-XXXXXX";
    if (mkdtemp(tempdir) == NULL) {
        fprintf(stderr, "bionova: mkdtemp failed: %s\n", strerror(errno));
        return 1;
    }

    char script_path[PATH_MAX];
    if (snprintf(script_path, sizeof(script_path), "%s/bioinfo-server-init.sh", tempdir) >= (int)sizeof(script_path)) {
        fprintf(stderr, "bionova: temp path too long\n");
        rmdir(tempdir);
        return 1;
    }

    int fd = open(script_path, O_WRONLY | O_CREAT | O_EXCL, 0700);
    if (fd < 0) {
        fprintf(stderr, "bionova: create embedded script failed: %s\n", strerror(errno));
        rmdir(tempdir);
        return 1;
    }

    if (write_all(fd, embedded_script, embedded_script_len) != 0) {
        fprintf(stderr, "bionova: write embedded script failed: %s\n", strerror(errno));
        close(fd);
        unlink(script_path);
        rmdir(tempdir);
        return 1;
    }
    close(fd);

    char **child_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (child_argv == NULL) {
        fprintf(stderr, "bionova: out of memory\n");
        unlink(script_path);
        rmdir(tempdir);
        return 1;
    }

    child_argv[0] = "bash";
    child_argv[1] = script_path;
    for (int i = 1; i < argc; i++) {
        child_argv[i + 1] = argv[i];
    }
    child_argv[argc + 1] = NULL;

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "bionova: fork failed: %s\n", strerror(errno));
        free(child_argv);
        unlink(script_path);
        rmdir(tempdir);
        return 1;
    }

    if (pid == 0) {
        execvp("bash", child_argv);
        fprintf(stderr, "bionova: exec bash failed: %s\n", strerror(errno));
        _exit(127);
    }

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
    unlink(script_path);
    rmdir(tempdir);

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

    return run_embedded(argc, argv);
}
