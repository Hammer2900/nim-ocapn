#include "glowcap_host.h"
#include "glowcap_ocapn.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fail(const char *what) {
    uint8_t message[256];
    size_t len = glowcap_host_last_error(message, sizeof message);
    fprintf(stderr, "tcp_greeter: %s: %.*s\n", what, (int)len, message);
    return 1;
}

typedef struct {
    int fd;
    GlowcapHostSession *session;
} Io;

static int32_t flush_action(void *ctx, GlowcapHost *host,
    const GlowcapHostAction *action, uint32_t *progressed) {
    (void)host;
    Io *io = (Io *)ctx;
    if (progressed) *progressed = 0;
    if (action->kind != GLOWCAP_HOST_ACTION_FLUSH || action->session != io->session)
        return GLOWCAP_ERR_INVALID_ARGUMENT;

    for (;;) {
        GlowcapManagedFrame frame;
        uint8_t prefix[GLOWCAP_HOST_OUTBOUND_PREFIX_CAP];
        size_t prefix_len = 0;
        int32_t rc = glowcap_host_session_take_outbound(
            io->session, &frame, prefix, sizeof prefix, &prefix_len);
        if (rc == GLOWCAP_ERR_WOULD_BLOCK) return GLOWCAP_OK;
        if (rc != GLOWCAP_OK) return rc;

        size_t total = prefix_len + frame.len;
        uint8_t *wire = malloc(total);
        if (!wire) {
            glowcap_managed_frame_release(&frame);
            return GLOWCAP_ERR_INTERNAL;
        }
        memcpy(wire, prefix, prefix_len);
        memcpy(wire + prefix_len, frame.bytes, frame.len);
        glowcap_managed_frame_release(&frame);
        size_t sent = 0;
        while (sent < total) {
            ssize_t n = send(io->fd, wire + sent, total - sent, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                free(wire);
                return GLOWCAP_ERR_IO;
            }
            sent += (size_t)n;
        }
        free(wire);
        if (progressed) *progressed = 1;
    }
}

static int32_t handled_action(void *ctx, GlowcapHost *host,
    const GlowcapHostAction *action, uint32_t *progressed) {
    (void)ctx;
    (void)host;
    if (progressed) *progressed = 1;
    if (action->kind == GLOWCAP_HOST_ACTION_SETTLE ||
        action->kind == GLOWCAP_HOST_ACTION_FAIL ||
        action->kind == GLOWCAP_HOST_ACTION_CLOSE)
        return GLOWCAP_OK;
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}

static int pump(GlowcapHost *host, Io *io) {
    GlowcapHostPumpHooks hooks = {
        .ctx = io,
        .flush = flush_action,
        .close = handled_action,
        .need_gift_id = NULL,
        .complete = handled_action,
        .dial = NULL,
    };
    int32_t rc = glowcap_host_pump_drain(host, &hooks, NULL, NULL);
    return rc == GLOWCAP_OK ? 0 : fail("pump");
}

static int32_t greeter(void *ctx, GlowcapHostTurn *turn,
    const uint8_t *verb, size_t verb_len, const GlowcapArgument *args,
    size_t args_len, GlowcapArgument *out_reply) {
    (void)ctx;
    (void)turn;
    (void)args;
    if (!verb || verb_len != 5 || memcmp(verb, "greet", 5) != 0 || args_len != 1)
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    static const uint8_t reply[] = "Hello, world";
    *out_reply = (GlowcapArgument){
        .kind = GLOWCAP_ARG_STRING,
        .bytes = reply,
        .bytes_len = sizeof reply - 1,
    };
    return GLOWCAP_OK;
}

static int make_listener(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if (bind(fd, (struct sockaddr *)&address, sizeof address) < 0 || listen(fd, 1) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    uint16_t port = argc == 2 ? (uint16_t)strtoul(argv[1], NULL, 10) : 42014;
    int listener = make_listener(port);
    if (listener < 0) return fail("listen");
    printf("tcp_greeter listening on 127.0.0.1:%u\n", port);
    fflush(stdout);

    int fd = accept(listener, NULL, NULL);
    close(listener);
    if (fd < 0) return fail("accept");

    uint8_t seed[64];
    memset(seed, 0x5a, 32);
    memset(seed + 32, 0xa5, 32);
    GlowcapHost *host = NULL;
    if (glowcap_host_new(seed, sizeof seed, GLOWCAP_DEFAULT_FRAME_CAP, 1,
                         GLOWCAP_CODEC_SYRUP, GLOWCAP_CAPTP_V1_0,
                         GLOWCAP_FEATURE_FULL, 0, 1, &host) != GLOWCAP_OK)
        return fail("host_new");

    char designator[64];
    snprintf(designator, sizeof designator, "127.0.0.1:%u", port);
    GlowcapLocatorView locator = {
        .abi_version = GLOWCAP_LOCATOR_VIEW_ABI_VERSION,
        .struct_size = sizeof locator,
        .transport = (const uint8_t *)"tcp", .transport_len = 3,
        .designator = (const uint8_t *)designator,
        .designator_len = strlen(designator),
        .hint_wire_form = GLOWCAP_HINTS_BOOLEAN_FALSE,
    };
    if (glowcap_host_set_advertised_locator(host, &locator) != GLOWCAP_OK)
        return fail("set_locator");

    GlowcapHostSession *session = NULL;
    if (glowcap_host_session_open_accepted(host, (const uint8_t *)"tcp", 3,
        GLOWCAP_DESIGNATOR_SCHEME_ADDRESS, NULL, 0, NULL, 0, &session) != GLOWCAP_OK)
        return fail("open_accepted");
    Io io = {.fd = fd, .session = session};
    if (pump(host, &io)) return 1;

    int published = 0;
    uint8_t buffer[65536];
    for (;;) {
        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        if (poll(&pfd, 1, 10000) <= 0) return fail("poll");
        ssize_t n = recv(fd, buffer, sizeof buffer, 0);
        if (n <= 0) return fail("recv");
        int32_t rc = glowcap_host_session_feed_bytes(session, buffer, (size_t)n);
        if (rc != GLOWCAP_OK && rc != GLOWCAP_ERR_WOULD_BLOCK) return fail("feed");
        if (pump(host, &io)) return 1;

        if (!published && glowcap_host_session_is_open(session)) {
            GlowcapReference ref;
            if (glowcap_host_session_publish(session,
                (const uint8_t *)"greeter", 7, greeter, NULL, NULL, &ref) != GLOWCAP_OK)
                return fail("publish");
            published = 1;
            fprintf(stderr, "tcp_greeter: session open, greeter published\n");
            if (pump(host, &io)) return 1;
        }
    }
}
