/*
 * hookling-hook - tell Hookling that something happened.
 *
 * Invoked by Claude Code hooks as:
 *
 *     hookling-hook <generic-event-name>
 *
 * Design constraints, in priority order:
 *
 *   1. NEVER get in Claude Code's way. Always exits 0, never writes to stdout
 *      (a UserPromptSubmit hook's stdout is injected into Claude's context),
 *      and gives up on the socket after ~150ms. If Hookling is not running there is
 *      no socket and this is a silent no-op.
 *
 *   2. NEVER leak content. The event name comes from argv - it is written
 *      literally into hooks.json and is never derived from the payload. The only
 *      thing read from stdin is the session id, which is immediately reduced to a
 *      64-bit hash; the payload is scanned through a small sliding window that is
 *      overwritten as it goes, so the prompt, tool arguments and tool output are
 *      never held in memory in full, never written anywhere, and never sent.
 *
 *   3. Be fast. PreToolUse and PostToolUse fire on every single tool call, so
 *      process startup dominates. That is why this is C: about a millisecond,
 *      against ten or more for a Swift or Python equivalent.
 *
 * Written in C rather than reusing hooklingctl for reason 3 alone. Both speak the
 * same one-line JSON protocol.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define CONNECT_TIMEOUT_MS 150
#define WINDOW_BYTES 8192
/* Enough overlap that the key and a full session id can never be split across
 * two reads. */
#define OVERLAP_BYTES 128
#define MAX_STDIN_BYTES (1024 * 1024)
#define SESSION_KEY "\"session_id\""
#define MAX_SESSION_CHARS 128

static int debug_enabled(void) {
    const char *value = getenv("HOOKLING_HOOK_DEBUG");
    return value != NULL && value[0] != '\0';
}

static void debug(const char *message) {
    if (debug_enabled()) {
        fprintf(stderr, "hookling-hook: %s\n", message);
    }
}

/* FNV-1a, 64-bit. Not a cryptographic hash and does not need to be: the session
 * id is already an opaque identifier, and hashing it means the pet holds a token
 * that is not the id itself and cannot be correlated back to a transcript. */
static uint64_t fnv1a(const char *data, size_t length) {
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < length; i++) {
        hash ^= (uint64_t)(unsigned char)data[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

/*
 * Scan stdin for the session id and hash it.
 *
 * Returns 1 and fills `out` (17 bytes: 16 hex digits plus a terminator) on
 * success, 0 otherwise. Reads through a sliding window so the payload is never
 * fully resident; the window is wiped before returning either way.
 */
static int read_session_token(char *out) {
    char window[WINDOW_BYTES + OVERLAP_BYTES];
    char session[MAX_SESSION_CHARS + 1];
    size_t carried = 0;
    size_t total = 0;
    int found = 0;

    memset(window, 0, sizeof(window));
    memset(session, 0, sizeof(session));

    while (!found && total < MAX_STDIN_BYTES) {
        ssize_t count = read(STDIN_FILENO, window + carried, WINDOW_BYTES);
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (count == 0) break; /* EOF */

        size_t available = carried + (size_t)count;
        total += (size_t)count;

        const char *key = memmem(window, available, SESSION_KEY, strlen(SESSION_KEY));
        if (key != NULL) {
            const char *cursor = key + strlen(SESSION_KEY);
            const char *end = window + available;

            while (cursor < end && (*cursor == ' ' || *cursor == '\t')) cursor++;
            if (cursor < end && *cursor == ':') cursor++;
            while (cursor < end && (*cursor == ' ' || *cursor == '\t')) cursor++;
            if (cursor < end && *cursor == '"') {
                cursor++;
                size_t length = 0;
                while (cursor < end && *cursor != '"' && length < MAX_SESSION_CHARS) {
                    session[length++] = *cursor++;
                }
                /* Only accept a value we saw terminated, so a session id split
                 * across reads is skipped rather than truncated and mis-hashed. */
                if (cursor < end && *cursor == '"' && length > 0) {
                    snprintf(out, 17, "%016llx",
                             (unsigned long long)fnv1a(session, length));
                    found = 1;
                }
            }
        }

        if (!found) {
            /* Keep a tail of the window so a key spanning two reads is still
             * matched, and drop everything else. */
            size_t keep = available < OVERLAP_BYTES ? available : OVERLAP_BYTES;
            memmove(window, window + available - keep, keep);
            carried = keep;
        }
    }

    /* Wipe both buffers: nothing derived from the payload outlives this call. */
    memset(window, 0, sizeof(window));
    memset(session, 0, sizeof(session));
    return found;
}

static int resolve_socket_path(char *out, size_t capacity) {
    const char *override = getenv("HOOKLING_SOCKET");
    if (override != NULL && override[0] != '\0') {
        if (strlen(override) >= capacity) return 0;
        snprintf(out, capacity, "%s", override);
        return 1;
    }

    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') return 0;

    int written = snprintf(out, capacity,
                           "%s/Library/Application Support/Hookling/hookling.sock", home);
    return written > 0 && (size_t)written < capacity;
}

/* Connect without ever blocking longer than CONNECT_TIMEOUT_MS. */
static int connect_with_timeout(const char *path) {
    struct sockaddr_un address;
    if (strlen(path) >= sizeof(address.sun_path)) {
        debug("socket path too long");
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", path);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) return fd;

    if (errno != EINPROGRESS) {
        /* No socket file, or nothing listening: Hookling is simply not running. */
        close(fd);
        return -1;
    }

    struct pollfd descriptor = {.fd = fd, .events = POLLOUT, .revents = 0};
    if (poll(&descriptor, 1, CONNECT_TIMEOUT_MS) != 1) {
        debug("connect timed out");
        close(fd);
        return -1;
    }

    int error = 0;
    socklen_t length = sizeof(error);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) != 0 || error != 0) {
        close(fd);
        return -1;
    }

    /* Back to blocking, but with a send timeout: a tiny write to an empty socket
     * buffer always succeeds immediately, and a bounded block is safer than
     * spinning on EAGAIN. */
    if (flags >= 0) fcntl(fd, F_SETFL, flags);
    struct timeval send_timeout = {.tv_sec = 0, .tv_usec = CONNECT_TIMEOUT_MS * 1000};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout));
    return fd;
}

int main(int argc, char **argv) {
    /* SIGPIPE would otherwise kill us mid-write if the pet quit a moment ago,
     * turning a silent no-op into a non-zero exit. */
    signal(SIGPIPE, SIG_IGN);

    if (argc < 2 || argv[1][0] == '\0') {
        debug("usage: hookling-hook <event> [--no-session]");
        return 0; /* still success: never disrupt the caller */
    }

    const char *event = argv[1];
    int want_session = 1;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--no-session") == 0) want_session = 0;
    }

    /* Validate the event name against a strict charset. It comes from our own
     * hooks.json, so this is belt-and-braces: it guarantees that whatever ends up
     * on the socket cannot be arbitrary text. */
    for (const char *c = event; *c != '\0'; c++) {
        if (!((*c >= 'a' && *c <= 'z') || *c == '_')) {
            debug("refusing a malformed event name");
            return 0;
        }
    }
    if (strlen(event) > 32) {
        debug("refusing an over-long event name");
        return 0;
    }

    char token[17];
    int have_token = 0;
    if (want_session) {
        have_token = read_session_token(token);
    }

    char message[128];
    int length;
    if (have_token) {
        length = snprintf(message, sizeof(message),
                          "{\"event\":\"%s\",\"session\":\"%s\"}\n", event, token);
    } else {
        length = snprintf(message, sizeof(message), "{\"event\":\"%s\"}\n", event);
    }
    if (length <= 0 || (size_t)length >= sizeof(message)) return 0;

    char path[512];
    if (!resolve_socket_path(path, sizeof(path))) {
        debug("could not determine the socket path");
        return 0;
    }

    int fd = connect_with_timeout(path);
    if (fd < 0) {
        debug("Hookling is not running");
        return 0;
    }

    ssize_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, message + written, (size_t)(length - written));
        if (count <= 0) {
            if (count < 0 && errno == EINTR) continue;
            break;
        }
        written += count;
    }
    close(fd);

    /* Always success. A desktop pet is never a reason for a tool call to fail. */
    return 0;
}
