#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define GUEST_DIR "/vguard"
#define OUTPUT_LIMIT (6u * 1024 * 1024)
#define CASE_LIMIT (1024u * 1024)

static char settings[CASE_LIMIT + 1];
static char *argv[1026] = { GUEST_DIR "/program" };
static char *envp[1025];

static _Noreturn void finish(void) {
    fflush(stdout);
    reboot(RB_POWER_OFF);
    _exit(125);
}

static _Noreturn void setup_error(const char *stage, int code) {
    printf("VGUARD_VM_ERROR %s %d\n", stage, code);
    finish();
}

static void connect_console(void) {
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    mount("proc", "/proc", "proc", 0, NULL);
    int console = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (console < 0 || dup2(console, STDOUT_FILENO) < 0)
        _exit(125);
    if (console != STDOUT_FILENO)
        close(console);
}

static size_t read_settings(void) {
    FILE *file = fopen(GUEST_DIR "/case", "rb");
    if (!file)
        setup_error("read-case", errno);
    size_t size = fread(settings, 1, sizeof settings, file);
    if (ferror(file) || size > CASE_LIMIT || size == 0 || settings[size - 1] != 0)
        setup_error("invalid-case", EINVAL);
    fclose(file);
    return size;
}

static void paths_from_settings(char **cwd) {
    size_t size = read_settings();
    size_t pos = strlen(settings) + 1;
    *cwd = settings;
    size_t args = 1;
    size_t env = 0;
    /* An argument count distinguishes empty arguments from environment fields. */
    if (pos >= size)
        setup_error("invalid-arguments", EINVAL);
    char *end;
    unsigned long count = strtoul(settings + pos, &end, 10);
    if (*end || count > 1024)
        setup_error("invalid-arguments", EINVAL);
    pos += strlen(settings + pos) + 1;
    for (; args <= count && pos < size; args++) {
        argv[args] = settings + pos;
        pos += strlen(settings + pos) + 1;
    }
    if (args <= count)
        setup_error("truncated-arguments", EINVAL);
    for (; env < 1024 && pos < size; env++) {
        envp[env] = settings + pos;
        pos += strlen(settings + pos) + 1;
    }
    if (pos != size)
        setup_error("too-many-environment-variables", E2BIG);
}

struct launch_problem {
    int stage;
    int error;
};

static _Noreturn void child_error(int error_fd, int stage) {
    struct launch_problem failure = { stage, errno };
    (void)write(error_fd, &failure, sizeof failure);
    _exit(125);
}

static void launch(const char *cwd, int child_error_fd) {
    const char *paths[] = { GUEST_DIR "/stdin", GUEST_DIR "/stdout", GUEST_DIR "/stderr" };
    for (int i = 0; i < 3; i++) {
        int flags = i == 0 ? O_RDONLY : O_WRONLY | O_CREAT | O_TRUNC;
        int fd = open(paths[i], flags, 0600);
        if (fd < 0 || dup2(fd, i) < 0)
            child_error(child_error_fd, i);
        if (fd != i)
            close(fd);
    }
    if (chdir(cwd))
        child_error(child_error_fd, 3);
    execve(argv[0], argv, envp);
    child_error(child_error_fd, 4);
}

struct result_stream {
    FILE *file;
    size_t bytes;
};

static struct result_stream result_file(const char *path, size_t *remaining, int optional) {
    FILE *file = fopen(path, "rb");
    if (!file) {
        if (optional && errno == ENOENT)
            return (struct result_stream){0};
        setup_error("open-result", errno);
    }
    struct stat info;
    if (fstat(fileno(file), &info) < 0 || info.st_size < 0 || !S_ISREG(info.st_mode))
        setup_error("stat-result", EINVAL);
    if ((uintmax_t)info.st_size > *remaining)
        setup_error("output-limit", EFBIG);
    *remaining -= (size_t)info.st_size;
    return (struct result_stream){ file, (size_t)info.st_size };
}

static void send_result(const char *label, struct result_stream stream) {
    static const char hex[] = "0123456789abcdef";
    unsigned char bytes[4096];
    char encoded[sizeof bytes * 2];
    printf("VGUARD_VM_%s ", label);
    if (stream.file) {
        while (stream.bytes) {
            size_t count = stream.bytes < sizeof bytes ? stream.bytes : sizeof bytes;
            size_t size = fread(bytes, 1, count, stream.file);
            if (size != count)
                setup_error("read-result", EIO);
            for (size_t i = 0; i < size; i++) {
                encoded[i * 2] = hex[bytes[i] >> 4];
                encoded[i * 2 + 1] = hex[bytes[i] & 15];
            }
            fwrite(encoded, 2, size, stdout);
            stream.bytes -= size;
        }
        fclose(stream.file);
    }
    putchar('\n');
}

int main(void) {
    connect_console();
    char *cwd;
    paths_from_settings(&cwd);
    int error_pipe[2];
    if (pipe2(error_pipe, O_CLOEXEC))
        setup_error("pipe", errno);
    pid_t child = fork();
    if (child < 0)
        setup_error("fork", errno);
    if (child == 0) {
        close(error_pipe[0]);
        launch(cwd, error_pipe[1]);
    }
    close(error_pipe[1]);
    struct launch_problem failure;
    ssize_t size;
    do {
        size = read(error_pipe[0], &failure, sizeof failure);
    } while (size < 0 && errno == EINTR);
    close(error_pipe[0]);
    if (size != 0) {
        static const char *const stages[] = { "stdin", "stdout", "stderr", "cwd", "exec" };
        if (size != sizeof failure || failure.stage < 0 || failure.stage > 4)
            setup_error("launch", EIO);
        setup_error(stages[failure.stage], failure.error);
    }
    int state;
    while (waitpid(child, &state, 0) < 0) {
        if (errno != EINTR)
            setup_error("wait", errno);
    }
    if (!WIFEXITED(state) && !WIFSIGNALED(state))
        setup_error("child-status", EINVAL);
    size_t remaining = OUTPUT_LIMIT;
    struct result_stream out = result_file(GUEST_DIR "/stdout", &remaining, 0);
    struct result_stream err = result_file(GUEST_DIR "/stderr", &remaining, 0);
    struct result_stream trace = result_file(GUEST_DIR "/native-ssa.bin", &remaining, 1);
    printf("VGUARD_VM_RESULT %s %d\n", WIFEXITED(state) ? "exited" : "signal",
           WIFEXITED(state) ? WEXITSTATUS(state) : WTERMSIG(state));
    send_result("STDOUT", out);
    send_result("STDERR", err);
    send_result("TRACE", trace);
    puts("VGUARD_VM_END");
    finish();
}
