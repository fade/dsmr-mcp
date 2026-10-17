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
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define LISP_PROGRAM "dsmr-bus-watch-lisp"
#define ADVICE_TAIL "This hook arms the next listener itself when your turn ends; do not start one."
#define DEFAULT_WAKE_SECONDS 6600ULL
#define HOOK_INPUT_MS 2000
#define HOOK_INPUT_MAX ((size_t)16 * 1024 * 1024)
#define MAX_BUS_NAME 32
#define DEFAULT_OUTAGE_GRACE 300ULL
#define OUTAGE_STAMP_SECONDS 3600
#define MAX_SOCKET_PATH 107
#define MAX_REPLY 8192
#define SETTLE_MS 1000

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
    int64_t wake_ms;
    const char *wake_text;
    int64_t grace_ms;
    char grace_text[24];
    char *socket_path;
    char *host_dir;
    char *stamp_path;
    struct buf request;
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

/* Milliseconds in SECONDS, capped far below overflow. */
static int64_t seconds_to_ms(unsigned long long seconds) {
    unsigned long long cap = (unsigned long long)INT64_MAX / 4000;
    return (int64_t)(seconds > cap ? cap : seconds) * 1000;
}

/* ------------------------------------------------------------------ request */

/* True when OCTET stands for itself in a request field: [A-Za-z0-9._~/]. */
static int unreserved_octet_p(unsigned char octet) {
    return (octet >= 'a' && octet <= 'z') || (octet >= 'A' && octet <= 'Z') ||
           (octet >= '0' && octet <= '9') || octet == '.' || octet == '_' ||
           octet == '~' || octet == '/';
}

/* Append " KEY=VALUE" to B, VALUE percent-encoded byte by byte with
   uppercase hex, or the bare `-` when VALUE is NULL. `-` inside a value is
   always encoded, so a bare `-` can only mean absent. */
static void buf_field(struct buf *b, const char *key, const char *value) {
    static const char hex[] = "0123456789ABCDEF";
    buf_str(b, " ");
    buf_str(b, key);
    buf_str(b, "=");
    if (!value) {
        buf_str(b, "-");
        return;
    }
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        if (unreserved_octet_p(*p)) {
            buf_add(b, (const char *)p, 1);
        } else {
            char escape[3] = {'%', hex[((unsigned)*p >> 4u) & 15u], hex[(unsigned)*p & 15u]};
            buf_add(b, escape, 3);
        }
    }
}

/* The wake request line for O, LF-terminated. */
static void build_request(struct buf *b, const struct options *o, const char *cwd) {
    char pid[24];
    snprintf(pid, sizeof pid, "%ld", (long)getpid());
    buf_str(b, "WAKE 1");
    buf_str(b, o->hook ? " hook=1" : " hook=0");
    buf_str(b, o->all_buses ? " allbuses=1" : " allbuses=0");
    buf_field(b, "agent", o->agent);
    buf_field(b, "ns", o->namespace);
    buf_field(b, "agentid", o->agent_id);
    buf_field(b, "envagent", getenv("DSMR_BUS_AGENT"));
    buf_field(b, "bus", o->bus);
    buf_field(b, "envbus", getenv("DSMR_BUS_SELECTOR"));
    buf_field(b, "cwd", cwd);
    buf_str(b, " pid=");
    buf_str(b, pid);
    buf_str(b, "\n");
}

/* The value of the hex digit C, or -1 when C is not one. */
static int hex_value(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    return -1;
}

/* Decode the percent escapes of FIELD in place. A malformed escape, and an
   escape for the NUL byte, are kept as they stand, so the result is still
   one C string. */
static void percent_decode(char *field) {
    char *out = field;
    for (char *in = field; *in;) {
        int hi = in[0] == '%' && in[1] ? hex_value(in[1]) : -1;
        int lo = hi >= 0 && in[2] ? hex_value(in[2]) : -1;
        if (lo >= 0 && (hi != 0 || lo != 0)) {
            *out++ = (char)(hi * 16 + lo);
            in += 3;
        } else {
            *out++ = *in++;
        }
    }
    *out = '\0';
}

/* ------------------------------------------------------------------ outputs */

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

/* Print the wake LINE that arrived on bus LABEL and exit: 0 by default, 2 in
   hook mode with the drain advice. */
static _Noreturn void event_exit(const struct client *c, const char *label, const char *line) {
    if (c->hook) {
        say(2, line, "\ndsmr-bus-watch: mail has arrived for you on bus ", label,
            ". Drain the bus now with bus-receive and act on what it holds. ", ADVICE_TAIL,
            "\n", (char *)NULL);
        _exit(2);
    }
    say(1, line, "\n", (char *)NULL);
    _exit(0);
}

/* Report that no watcher serves ID on bus LABEL and exit: 1 by default; in
   hook mode 2 with advice when DUE, else 0 in silence. */
static _Noreturn void nowatcher_exit(const struct client *c, const char *label, const char *id,
                                     int due) {
    if (!c->hook) {
        say(2, "dsmr-bus-watch: no detached watcher is running for ", id, " on bus ", label,
            "; start one with --detach, then wake again\n", (char *)NULL);
        say(1, "nowatcher bus=", label, "\n", (char *)NULL);
        _exit(1);
    }
    if (!due)
        _exit(0);
    say(2, "nowatcher bus=", label, "\ndsmr-bus-watch: no detached watcher is running for ", id,
        " on bus ", label,
        ", so no mail can wake you. Start one with dsmr-bus-watch --detach and your usual "
        "--bus and identity flags. ",
        ADVICE_TAIL, "\n", (char *)NULL);
    _exit(2);
}

/* Create each missing directory of PATH with mode 0700. */
static void make_directories(const char *path) {
    struct buf b = {0};
    buf_str(&b, path);
    for (char *p = b.p + 1; *p; p++) {
        if (*p != '/')
            continue;
        *p = '\0';
        mkdir(b.p, 0700);
        *p = '/';
    }
    mkdir(b.p, 0700);
    free(b.p);
}

/* True when the outage notice is due for this identity: its stamp is absent
   or at least an hour old, or dated in the future. A due notice refreshes the
   stamp, creating the host directory when it is missing. */
static int outage_notice_due_p(const struct client *c) {
    struct stat st;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    if (stat(c->stamp_path, &st) == 0) {
        long long age = (long long)now.tv_sec - (long long)st.st_mtime;
        if (age >= 0 && age < OUTAGE_STAMP_SECONDS)
            return 0;
    }
    int fd = open(c->stamp_path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 && errno == ENOENT) {
        make_directories(c->host_dir);
        fd = open(c->stamp_path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    }
    if (fd >= 0) {
        futimens(fd, NULL);
        close(fd);
    }
    return 1;
}

/* Report a service outage that has lasted the whole grace and exit: 1 by
   default with `nowatcher`; in hook mode 2 with advice when the hourly notice
   is due, else 0 in silence. */
static _Noreturn void outage_exit(const struct client *c) {
    if (!c->hook) {
        say(2, "dsmr-bus-watch: the host bus service has not answered for ", c->grace_text,
            " seconds, so no mail can wake you; check it with systemctl --user status "
            "dsmr-bus-host, then wake again\n",
            (char *)NULL);
        say(1, "nowatcher bus=", c->label, "\n", (char *)NULL);
        _exit(1);
    }
    if (!outage_notice_due_p(c))
        _exit(0);
    say(2, "nowatcher bus=", c->label,
        "\ndsmr-bus-watch: the host bus service has not answered for ", c->grace_text,
        " seconds, so no mail can wake you. Check it with systemctl --user status "
        "dsmr-bus-host. ",
        ADVICE_TAIL, "\n", (char *)NULL);
    _exit(2);
}

/* -------------------------------------------------------------- the service */

/* A connected socket to the service, or -1. The path must hold a socket
   owned by this uid and fit a unix-domain address; anything else counts as
   the service being unreachable. The connect itself never blocks, so a
   service with a full backlog is an outage, not a hang. */
static int connect_service(const struct client *c) {
    size_t n = strlen(c->socket_path);
    struct stat st;
    if (n > MAX_SOCKET_PATH || stat(c->socket_path, &st) != 0 || !S_ISSOCK(st.st_mode) ||
        st.st_uid != getuid())
        return -1;
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, c->socket_path, n + 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);
        return -1;
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

/* Act on one reply LINE (without its LF). Every answer the contract defines
   ends the process; return means the reply counts as an outage: ERR busy,
   version or bad-request, or anything unrecognised. ERR bad-bus hands the
   original argv to the SBCL program, whose refusal names the problem. */
static void handle_reply(const struct client *c, char *line) {
    if (strncmp(line, "EVENT ", 6) == 0) {
        char *label = line + 6;
        char *space = strchr(label, ' ');
        if (!space || space == label)
            return;
        *space = '\0';
        event_exit(c, label, space + 1);
    }
    if (strncmp(line, "NOWATCHER ", 10) == 0) {
        char *label = line + 10;
        char *id = strchr(label, ' ');
        if (!id || id == label)
            return;
        *id++ = '\0';
        char *due = strchr(id, ' ');
        if (!due || due == id)
            return;
        *due++ = '\0';
        if (strcmp(due, "due=0") != 0 && strcmp(due, "due=1") != 0)
            return;
        percent_decode(id);
        nowatcher_exit(c, label, id, due[4] == '1');
    }
    if (strcmp(line, "SUPERSEDED") == 0)
        _exit(0);
    if (strcmp(line, "ERR bad-bus") == 0 || strncmp(line, "ERR bad-bus ", 12) == 0)
        run_lisp_program(c->argv);
}

/* Send the request on FD and wait for the reply, up to DEADLINE (-1 for
   none). A reply the contract defines ends the process, as does the
   deadline. Returns when the connection fails, ends or carries an outage
   reply, which includes a reply over MAX_REPLY bytes and one holding a NUL
   byte: 1 when it had stayed open for SETTLE_MS after the request went,
   else 0. */
static int converse(const struct client *c, int fd, int64_t deadline) {
    if (!write_all(fd, c->request.p, c->request.len))
        return 0;
    int64_t sent_at = now_ms();
    int settled = 0;
    char reply[MAX_REPLY + 1];
    size_t len = 0;
    for (;;) {
        int64_t t = now_ms();
        if (!settled && t - sent_at >= SETTLE_MS)
            settled = 1;
        if (deadline >= 0 && t >= deadline)
            idle_exit(c);
        int64_t wait = deadline >= 0 ? deadline - t : -1;
        if (!settled && (wait < 0 || sent_at + SETTLE_MS - t < wait))
            wait = sent_at + SETTLE_MS - t;
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int r = poll(&p, 1, wait > INT_MAX ? INT_MAX : (int)wait);
        if (r < 0 && errno == EINTR)
            continue;
        if (r < 0)
            return settled;
        if (r == 0)
            continue;
        ssize_t n = read(fd, reply + len, MAX_REPLY - len);
        if (n < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (n <= 0)
            return settled;
        char *lf = memchr(reply + len, '\n', (size_t)n);
        len += (size_t)n;
        if (lf) {
            if (memchr(reply, '\0', (size_t)(lf - reply)))
                return settled;
            *lf = '\0';
            handle_reply(c, reply);
            return settled;
        }
        if (len == MAX_REPLY)
            return settled;
    }
}

/* Wait for the next wake line and print it. A refused connection, an end of
   file or an outage reply is never an exit: the client reconnects after 100,
   250, 500, then 1000 ms and sends its request again. The idle line arrives
   at the wake deadline whatever the service does, and an outage that lasts
   the whole grace ends in `nowatcher`. */
static _Noreturn void wait_for_wake(const struct client *c) {
    static const int64_t backoff[] = {100, 250, 500, 1000};
    size_t step = 0;
    int64_t deadline = c->wake_ms ? now_ms() + c->wake_ms : -1;
    int64_t outage_since = -1;
    for (;;) {
        int64_t t = now_ms();
        if (deadline >= 0 && t >= deadline)
            idle_exit(c);
        if (outage_since >= 0 && t - outage_since >= c->grace_ms)
            outage_exit(c);
        int fd = connect_service(c);
        if (fd >= 0) {
            int settled = converse(c, fd, deadline);
            close(fd);
            if (settled) {
                outage_since = -1;
                step = 0;
            }
        }
        t = now_ms();
        if (outage_since < 0)
            outage_since = t;
        int64_t pause_ms = backoff[step];
        if (step + 1 < sizeof backoff / sizeof backoff[0])
            step++;
        if (deadline >= 0 && deadline - t < pause_ms)
            pause_ms = deadline - t;
        if (outage_since + c->grace_ms - t < pause_ms)
            pause_ms = outage_since + c->grace_ms - t;
        sleep_ms(pause_ms);
    }
}

/* 32-bit FNV-1a of the N bytes at DATA, continuing from HASH. */
static uint32_t fnv1a(uint32_t hash, const char *data, size_t n) {
    for (size_t i = 0; i < n; i++)
        hash = (hash ^ (unsigned char)data[i]) * 16777619u;
    return hash;
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
    struct buf cwd_dir = {0};
    buf_str(&cwd_dir, cwd ? cwd : "");
    if (cwd_dir.len == 0 || cwd_dir.p[cwd_dir.len - 1] != '/')
        buf_str(&cwd_dir, "/");
    if (!explicit_id && name && !o.namespace) {
        struct buf w = {0};
        buf_str(&w, "dsmr-bus-watch: no --namespace given; inferring ");
        buf_quoted(&w, cwd_dir.p);
        buf_str(&w, " from the working directory. It must match the project root the MCP "
                    "session uses, or this watcher reads the wrong cursor.\n");
        write_all(2, w.p, w.len);
        free(w.p);
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

    char *home = state_home();
    if (!home) {
        put(2, "dsmr-bus-watch: neither XDG_STATE_HOME nor HOME is set; cannot find the "
               "host bus service\n");
        _exit(64);
    }

    struct client c = {
        .argv = argv,
        .hook = o.hook,
        .label = o.all_buses ? "*" : (bus ? bus : "default"),
        .wake_ms = seconds_to_ms(o.wake_seconds),
        .wake_text = o.wake_text,
    };
    unsigned long long grace;
    const char *grace_env = getenv("DSMR_WAKE_OUTAGE_GRACE_SECONDS");
    if (!grace_env || !parse_nonneg(grace_env, &grace, c.grace_text, sizeof c.grace_text)) {
        grace = DEFAULT_OUTAGE_GRACE;
        snprintf(c.grace_text, sizeof c.grace_text, "%llu", grace);
    }
    c.grace_ms = seconds_to_ms(grace);

    struct buf path = {0};
    buf_str(&path, home);
    buf_str(&path, "/dsmr-mcp/host");
    c.host_dir = path.p;
    path = (struct buf){0};
    buf_str(&path, c.host_dir);
    buf_str(&path, "/wake.sock");
    c.socket_path = path.p;

    /* The outage stamp is keyed on the identity as typed: the explicit id
       alone, else the name, a NUL and the namespace given or inferred. */
    const char *key_name = explicit_id ? o.agent_id : name;
    const char *key_namespace = explicit_id ? "" : (o.namespace ? o.namespace : cwd_dir.p);
    uint32_t hash = fnv1a(2166136261u, key_name, strlen(key_name));
    hash = fnv1a(hash, "", 1);
    hash = fnv1a(hash, key_namespace, strlen(key_namespace));
    char stamp[40];
    snprintf(stamp, sizeof stamp, "/wake-outage-%08x.stamp", (unsigned)hash);
    path = (struct buf){0};
    buf_str(&path, c.host_dir);
    buf_str(&path, stamp);
    c.stamp_path = path.p;

    build_request(&c.request, &o, cwd);
    free(cwd);
    free(cwd_dir.p);
    free(home);
    wait_for_wake(&c);
}

int main(int argc, char **argv) {
    if (!plain_wake_p(argc, argv))
        run_lisp_program(argv);
    return run_client(argc, argv);
}
