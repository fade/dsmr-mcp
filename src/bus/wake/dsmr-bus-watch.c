/* SPDX-License-Identifier: AGPL-3.0-or-later */
/*
 * dsmr-bus-watch: the installed bus watcher command.
 *
 * Two programs in one small static binary:
 *   - a front end that runs the SBCL program, dsmr-bus-watch-lisp in the
 *     same directory, for every mode except a plain wake, passing argv on
 *     unchanged;
 *   - the wake client, which waits for the next wake line addressed to one
 *     identity and prints exactly what the SBCL listener prints, with the
 *     same exit statuses.
 *
 * The wake client parses its arguments as leniently as the SBCL program:
 * an unknown flag, a dangling value or a bad number earns one warning and
 * is otherwise ignored, so a mistyped arm line still gets a listener.
 *
 * Built with -static, so nothing here may reach glibc's name-service
 * lookups for users or hosts; every path comes from the environment.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LISP_PROGRAM "dsmr-bus-watch-lisp"
#define ADVICE_TAIL "This hook arms the next listener itself when your turn ends; do not start one."
#define DEFAULT_WAKE_SECONDS 6600ULL
#define HOOK_INPUT_MS 2000
#define HOOK_INPUT_MAX (16u * 1024u * 1024u)
#define MAX_BUS_NAME 32

/* ------------------------------------------------------------- flag tables */

/* Flags that take the next argument as their value. */
static const char *const value_flags[] = {
    "--agent", "--namespace", "--bus", "--agent-id", "--wal", "--cursors-dir",
    "--wake-seconds", "--deaf-seconds", "--stall-seconds", "--after",
    "--poll-ms", "--recycle-seconds", "--live-window-seconds", NULL};

/* Value flags whose value must be a non-negative integer. */
static const char *const numeric_flags[] = {
    "--wake-seconds", "--deaf-seconds", "--stall-seconds", "--after",
    "--poll-ms", "--recycle-seconds", "--live-window-seconds", NULL};

/* Flags that take no value. */
static const char *const bare_flags[] = {
    "-h", "--help", "--stream", "--check-live", "--host-status",
    "--host-restore", "--host-failed", "--fleet-log", "--detach",
    "--detached-child", "--reap", "--park", "--unpark", "--all-buses",
    "--wake", "--hook", "--wait-for-arm", NULL};

/* Any of these sends a --wake argv to the SBCL program. */
static const char *const lisp_modes[] = {
    "-h", "--help", "--fleet-log", "--host-status", "--host-failed",
    "--host-restore", "--check-live", "--park", "--unpark", "--reap", NULL};

/* Names a bus may not take, compared case-insensitively. */
static const char *const reserved_bus_names[] = {
    "default", "cursors", "watch", "roster", "members", "bus.wal",
    "bus.wal.generation", "broker.lock", "broker.identity", "broker.log",
    "submit.ipc", "pub.ipc", ".", "..", NULL};

static int in_list(const char *s, const char *const *list) {
    for (; *list; list++)
        if (strcmp(s, *list) == 0)
            return 1;
    return 0;
}

/* ----------------------------------------------------------------- buffers */

struct buf {
    char *p;
    size_t len;
    size_t cap;
};

static _Noreturn void out_of_memory(void) {
    static const char msg[] = "dsmr-bus-watch: out of memory\n";
    ssize_t ignored = write(2, msg, sizeof msg - 1);
    (void)ignored;
    _exit(70);
}

static void buf_add(struct buf *b, const char *data, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1)
            cap *= 2;
        char *p = realloc(b->p, cap);
        if (!p)
            out_of_memory();
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->len, data, n);
    b->len += n;
    b->p[b->len] = '\0';
}

static void buf_str(struct buf *b, const char *s) { buf_add(b, s, strlen(s)); }

/* Append S as the Lisp reader prints a string: in double quotes, with each
   double quote and backslash preceded by a backslash. */
static void buf_quoted(struct buf *b, const char *s) {
    buf_add(b, "\"", 1);
    for (; *s; s++) {
        if (*s == '"' || *s == '\\')
            buf_add(b, "\\", 1);
        buf_add(b, s, 1);
    }
    buf_add(b, "\"", 1);
}

/* ------------------------------------------------------------------ output */

/* Write all N bytes of DATA to FD, retrying short and interrupted writes.
   Returns 1 on success, 0 on any other error. */
static int write_all(int fd, const char *data, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, data, n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return 0;
        }
        data += w;
        n -= (size_t)w;
    }
    return 1;
}

static void put(int fd, const char *s) { write_all(fd, s, strlen(s)); }

/* Write the concatenation of the NULL-terminated string arguments to FD in
   one write, so concurrent writers never interleave inside a line. */
static void say(int fd, ...) {
    struct buf b = {0};
    va_list ap;
    va_start(ap, fd);
    for (const char *s; (s = va_arg(ap, const char *));)
        buf_str(&b, s);
    va_end(ap);
    if (b.len)
        write_all(fd, b.p, b.len);
    free(b.p);
}

/* ------------------------------------------------------------------ clocks */

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Sleep MS milliseconds on the monotonic clock. */
static void sleep_ms(int64_t ms) {
    if (ms <= 0)
        return;
    struct timespec until;
    clock_gettime(CLOCK_MONOTONIC, &until);
    until.tv_sec += ms / 1000;
    until.tv_nsec += (ms % 1000) * 1000000;
    if (until.tv_nsec >= 1000000000) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000;
    }
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL) == EINTR)
        ;
}

/* --------------------------------------------------------------- front end */

/* Replace this process with the SBCL program beside this binary, passing
   ARGV unchanged, argv[0] included. Exits 127 when it cannot be run. */
static _Noreturn void run_lisp_program(char **argv) {
    char path[PATH_MAX];
    const char *shown = LISP_PROGRAM;
    int err;
    ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
    if (n < 0) {
        err = errno;
    } else {
        path[n] = '\0';
        char *slash = strrchr(path, '/');
        size_t dir = slash ? (size_t)(slash - path) + 1 : 0;
        if (dir + sizeof LISP_PROGRAM > sizeof path) {
            err = ENAMETOOLONG;
        } else {
            memcpy(path + dir, LISP_PROGRAM, sizeof LISP_PROGRAM);
            shown = path;
            signal(SIGPIPE, SIG_DFL);
            signal(SIGTERM, SIG_DFL);
            execv(path, argv);
            err = errno;
        }
    }
    say(2, "dsmr-bus-watch: cannot run ", shown, ": ", strerror(err), "\n", (char *)NULL);
    _exit(127);
}

/* True when ARGV asks for a plain wake: --wake is present and no flag that
   belongs to the SBCL program is. The value after a value flag is skipped,
   so a flag's value is never read as a mode. */
static int plain_wake_p(int argc, char **argv) {
    int wake = 0;
    for (int i = 1; i < argc; i++) {
        if (in_list(argv[i], value_flags)) {
            i++;
            continue;
        }
        if (in_list(argv[i], lisp_modes))
            return 0;
        if (strcmp(argv[i], "--wake") == 0)
            wake = 1;
    }
    return wake;
}

/* ---------------------------------------------------------------- parsing */

struct options {
    const char *agent;
    const char *namespace;
    const char *bus;
    const char *agent_id;
    int hook;
    int all_buses;
    unsigned long long wake_seconds;
    char wake_text[24];
};

static int lisp_blank_p(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r';
}

/* Parse S as the SBCL program does a numeric flag: optional surrounding
   blanks, an optional sign, decimal digits, and a value of at least 0.
   On success stores the value (saturated at ULLONG_MAX) in *VALUE and its
   canonical decimal text in TEXT, and returns 1; otherwise returns 0. */
static int parse_nonneg(const char *s, unsigned long long *value, char *text, size_t text_size) {
    while (lisp_blank_p(*s))
        s++;
    int negative = 0;
    if (*s == '+' || *s == '-')
        negative = *s++ == '-';
    const char *digits = s;
    while (*s >= '0' && *s <= '9')
        s++;
    const char *digits_end = s;
    while (lisp_blank_p(*s))
        s++;
    if (digits == digits_end || *s != '\0')
        return 0;
    while (digits < digits_end - 1 && *digits == '0')
        digits++;
    if (negative && !(digits_end - digits == 1 && *digits == '0'))
        return 0;
    unsigned long long v = 0;
    for (const char *d = digits; d < digits_end; d++) {
        unsigned digit = (unsigned)(*d - '0');
        v = v > (ULLONG_MAX - digit) / 10 ? ULLONG_MAX : v * 10 + digit;
    }
    size_t len = (size_t)(digits_end - digits);
    if (len >= text_size) {
        v = ULLONG_MAX;
        len = text_size - 1;
    }
    memcpy(text, digits, len);
    text[len] = '\0';
    *value = v;
    return 1;
}

/* Parse ARGV into O, appending each warning the SBCL program would print to
   WARNINGS, in argv order. */
static void parse_args(int argc, char **argv, struct options *o, struct buf *warnings) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (in_list(arg, value_flags)) {
            if (i + 1 >= argc) {
                buf_str(warnings, "dsmr-bus-watch: ");
                buf_str(warnings, arg);
                buf_str(warnings, " requires a value but none followed; ignoring it\n");
                continue;
            }
            const char *value = argv[++i];
            if (in_list(arg, numeric_flags)) {
                unsigned long long n;
                char text[24];
                if (!parse_nonneg(value, &n, text, sizeof text)) {
                    buf_str(warnings, "dsmr-bus-watch: ");
                    buf_str(warnings, arg);
                    buf_str(warnings, " expects a non-negative integer, got ");
                    buf_quoted(warnings, value);
                    buf_str(warnings, "; keeping the default\n");
                } else if (strcmp(arg, "--wake-seconds") == 0) {
                    o->wake_seconds = n;
                    memcpy(o->wake_text, text, sizeof o->wake_text);
                }
            } else if (strcmp(arg, "--agent") == 0) {
                o->agent = value;
            } else if (strcmp(arg, "--namespace") == 0) {
                o->namespace = value;
            } else if (strcmp(arg, "--bus") == 0) {
                o->bus = value;
            } else if (strcmp(arg, "--agent-id") == 0) {
                o->agent_id = value;
            }
        } else if (in_list(arg, bare_flags)) {
            if (strcmp(arg, "--hook") == 0)
                o->hook = 1;
            else if (strcmp(arg, "--all-buses") == 0)
                o->all_buses = 1;
        } else {
            buf_str(warnings, "dsmr-bus-watch: unknown argument ");
            buf_quoted(warnings, arg);
            buf_str(warnings, " ignored; continuing on defaults\n");
        }
    }
}

/* S when it is a non-empty string, else NULL. */
static const char *present(const char *s) { return s && *s ? s : NULL; }

/* True unless NAME certainly breaks the bus-name rule: at most 32
   characters, only ASCII alphanumerics, `-`, `_` and `.`, and not a reserved
   name. A name holding a non-ASCII byte is left to the service, which applies
   the full Unicode rule and answers ERR bad-bus. */
static int bus_name_acceptable_p(const char *name) {
    size_t n = strlen(name);
    for (size_t i = 0; i < n; i++)
        if ((unsigned char)name[i] >= 0x80)
            return 1;
    if (n == 0 || n > MAX_BUS_NAME)
        return 0;
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
        if (!ok)
            return 0;
    }
    for (const char *const *r = reserved_bus_names; *r; r++)
        if (strcasecmp(name, *r) == 0)
            return 0;
    return 1;
}

/* --------------------------------------------------------------- hook input */

static int json_blank_p(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

/* True when TEXT holds "agent_id", optional blanks, a colon, optional
   blanks, and a string value that is not empty. Claude Code sets that key
   only for a hook fired inside a subagent. */
static int names_subagent_p(const char *text, size_t len) {
    static const char key[] = "\"agent_id\"";
    size_t klen = sizeof key - 1;
    for (size_t start = 0; start + klen <= len; start++) {
        if (memcmp(text + start, key, klen) != 0)
            continue;
        size_t i = start + klen;
        while (i < len && json_blank_p(text[i]))
            i++;
        if (i >= len || text[i] != ':')
            continue;
        size_t j = i + 1;
        while (j < len && json_blank_p(text[j]))
            j++;
        if (j + 1 < len && text[j] == '"' && text[j + 1] != '"')
            return 1;
    }
    return 0;
}

/* Read standard input to its end, giving up after two seconds with what has
   arrived, and report whether it names a subagent. A terminal on standard
   input is not read. */
static int hook_input_names_subagent_p(void) {
    if (isatty(0))
        return 0;
    struct buf in = {0};
    int64_t end = now_ms() + HOOK_INPUT_MS;
    for (;;) {
        int64_t left = end - now_ms();
        if (left <= 0)
            break;
        struct pollfd p = {.fd = 0, .events = POLLIN};
        int r = poll(&p, 1, (int)left);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (r == 0)
            break;
        char chunk[4096];
        ssize_t n = read(0, chunk, sizeof chunk);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            break;
        }
        if (n == 0)
            break;
        buf_add(&in, chunk, (size_t)n);
        if (in.len >= HOOK_INPUT_MAX)
            break;
    }
    int found = in.p ? names_subagent_p(in.p, in.len) : 0;
    free(in.p);
    return found;
}

/* ------------------------------------------------------------------ client */

struct client {
    char **argv;
    int hook;
    const char *label;
    unsigned long long wake_seconds;
    const char *wake_text;
    char *state_home;
};

static void on_sigterm(int signo) {
    (void)signo;
    _exit(143);
}

static void install_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigterm;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
}

/* The state home: $XDG_STATE_HOME when non-empty, else $HOME/.local/state,
   without a trailing slash. NULL when neither variable is set. */
static char *state_home(void) {
    const char *xdg = present(getenv("XDG_STATE_HOME"));
    const char *home = present(getenv("HOME"));
    struct buf b = {0};
    if (xdg) {
        buf_str(&b, xdg);
    } else if (home) {
        buf_str(&b, home);
        while (b.len > 1 && b.p[b.len - 1] == '/')
            b.p[--b.len] = '\0';
        buf_str(&b, "/.local/state");
    } else {
        return NULL;
    }
    while (b.len > 1 && b.p[b.len - 1] == '/')
        b.p[--b.len] = '\0';
    return b.p;
}

/* Print the idle line for the mode and exit: 0 by default, 2 in hook mode
   with the renewal advice. */
static _Noreturn void idle_exit(const struct client *c) {
    if (c->hook) {
        say(2, "idle wake-seconds=", c->wake_text, "\ndsmr-bus-watch: no mail arrived in ",
            c->wake_text,
            " seconds; this wake only renews the listener and there is nothing to drain. ",
            ADVICE_TAIL, "\n", (char *)NULL);
        _exit(2);
    }
    say(1, "idle wake-seconds=", c->wake_text, "\n", (char *)NULL);
    _exit(0);
}

/* Wait for the wake deadline alone; no service is contacted. A deadline of
   0 waits for ever. */
static _Noreturn void wait_for_wake(const struct client *c) {
    if (c->wake_seconds == 0)
        for (;;)
            pause();
    unsigned long long cap = (unsigned long long)INT64_MAX / 1000 / 2;
    int64_t deadline = now_ms() + (int64_t)(c->wake_seconds > cap ? cap : c->wake_seconds) * 1000;
    for (int64_t t; (t = now_ms()) < deadline;)
        sleep_ms(deadline - t);
    idle_exit(c);
}

static int run_client(int argc, char **argv) {
    struct options o = {.wake_seconds = DEFAULT_WAKE_SECONDS, .wake_text = "6600"};
    struct buf warnings = {0};
    parse_args(argc, argv, &o, &warnings);

    const char *bus = present(o.bus) ? o.bus : present(getenv("DSMR_BUS_SELECTOR"));
    if (bus && !bus_name_acceptable_p(bus))
        run_lisp_program(argv);
    if (warnings.len)
        write_all(2, warnings.p, warnings.len);
    free(warnings.p);

    const char *name = present(o.agent) ? o.agent : present(getenv("DSMR_BUS_AGENT"));
    int explicit_id = present(o.agent_id) != NULL;
    char *cwd = getcwd(NULL, 0);
    if (!explicit_id && name && !o.namespace) {
        struct buf w = {0};
        struct buf dir = {0};
        buf_str(&dir, cwd ? cwd : "");
        if (dir.len == 0 || dir.p[dir.len - 1] != '/')
            buf_str(&dir, "/");
        buf_str(&w, "dsmr-bus-watch: no --namespace given; inferring ");
        buf_quoted(&w, dir.p);
        buf_str(&w, " from the working directory. It must match the project root the MCP "
                    "session uses, or this watcher reads the wrong cursor.\n");
        write_all(2, w.p, w.len);
        free(w.p);
        free(dir.p);
    }
    if (!explicit_id && !name) {
        if (o.hook)
            _exit(0);
        put(2, "dsmr-bus-watch: --wake needs a resolved identity (pass --agent with "
               "--namespace, or --agent-id); the detached log is keyed on it.\n");
        _exit(2);
    }

    install_signals();
    if (o.hook && hook_input_names_subagent_p())
        _exit(0);

    struct client c = {
        .argv = argv,
        .hook = o.hook,
        .label = o.all_buses ? "*" : (bus ? bus : "default"),
        .wake_seconds = o.wake_seconds,
        .wake_text = o.wake_text,
        .state_home = state_home(),
    };
    if (!c.state_home) {
        put(2, "dsmr-bus-watch: neither XDG_STATE_HOME nor HOME is set; cannot find the "
               "host bus service\n");
        _exit(64);
    }
    free(cwd);
    wait_for_wake(&c);
}

int main(int argc, char **argv) {
    if (!plain_wake_p(argc, argv))
        run_lisp_program(argv);
    return run_client(argc, argv);
}
