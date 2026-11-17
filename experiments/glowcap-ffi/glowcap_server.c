#include "glowcap_driver.h"
#include "glowcap_net_transport_tcp.h"
#include "glowcap_ocapn.h"
#include <stdio.h>
#include <string.h>

static int32_t greet(void *ctx, GlowcapHostTurn *turn, const uint8_t *verb, size_t verb_len,
    const GlowcapArgument *args, size_t args_len, GlowcapArgument *reply) {
    static char text[256];
    (void)ctx; (void)turn;
    if (verb_len != 5 || memcmp(verb, "greet", 5) != 0 || args_len != 1 ||
        args[0].kind != GLOWCAP_ARG_STRING) return GLOWCAP_ERR_INVALID_ARGUMENT;
    int n = snprintf(text, sizeof text, "Hello, %.*s", (int)args[0].bytes_len, args[0].bytes);
    if (n < 0 || (size_t)n >= sizeof text) return GLOWCAP_ERR_INVALID_ARGUMENT;
    memset(reply, 0, sizeof *reply);
    reply->kind = GLOWCAP_ARG_STRING;
    reply->bytes = (const uint8_t *)text;
    reply->bytes_len = (size_t)n;
    return GLOWCAP_OK;
}

int main(void) {
    unsigned char seed[64]; memset(seed, 0x33, sizeof seed); memset(seed + 32, 0x77, 32);
    GlowcapHost *host = NULL; GlowcapDriverLoop *loop = NULL; GlowcapTcpNetlayer *tcp = NULL;
    GlowcapDriverFailure failure = { GLOWCAP_DRIVER_FAILURE_ABI_VERSION, sizeof failure };
    GlowcapDriverOptions opts = { GLOWCAP_DRIVER_OPTIONS_ABI_VERSION, sizeof opts,
        GLOWCAP_DRIVER_DEFAULT_WIRE_BUFFER_BYTES, GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS,
        GLOWCAP_DRIVER_DEFAULT_HANDSHAKE_MS, GLOWCAP_DRIVER_DEFAULT_LISTENER_SETUP_MS,
        GLOWCAP_DRIVER_DEFAULT_SETTLE_MS, GLOWCAP_DRIVER_DEFAULT_BUSY_POLL_NS };
    GlowcapTcpConfig cfg = { {0,0,0}, GLOWCAP_TCP_PROFILE_TCP };
    int rc = glowcap_host_new(seed, sizeof seed, GLOWCAP_DEFAULT_FRAME_CAP, 0,
        GLOWCAP_CODEC_SYRUP, GLOWCAP_CAPTP_V1_0, GLOWCAP_FEATURE_FULL, 0, 1, &host);
    if (rc) return rc;
    rc = glowcap_driver_take_host(host, &opts, &loop); if (rc) return rc; host = NULL;
    rc = glowcap_tcp_netlayer_new(&cfg, &tcp); if (rc) return rc;
    GlowcapTransportProvider provider; rc = glowcap_tcp_transport_provider(tcp, &provider); if (rc) return rc;
    rc = glowcap_driver_add_provider(loop, &provider, &failure); if (rc) return rc;
    uint64_t listener = 0;
    rc = glowcap_driver_listen(loop, (const uint8_t *)"tcp", 3,
        (const uint8_t *)"127.0.0.1:46659", 15, NULL, &listener); if (rc) return rc;
    puts("ocapn://127.0.0.1%3A46659.tcp"); fflush(stdout);
    int published = 0;
    for (unsigned i = 0; i < 30000; ++i) {
        rc = glowcap_driver_step(loop, 10); if (rc != GLOWCAP_OK && rc != GLOWCAP_ERR_WOULD_BLOCK) break;
        GlowcapDriverEvent ev;
        while (glowcap_driver_next_event(loop, &ev) == GLOWCAP_OK) {
            fprintf(stderr, "event=%u primary=%d secondary=%d\n", ev.kind, ev.primary_result, ev.secondary_result);
            if (ev.kind == GLOWCAP_DRIVER_EVENT_LISTENER_READY)
                glowcap_driver_listener_select(loop, ev.listener_id);
            if (ev.kind == GLOWCAP_DRIVER_EVENT_ACCEPTED) {
                if (glowcap_driver_session_serve(loop, ev.session) == GLOWCAP_OK && !published) {
                    GlowcapReference ref;
                    if (glowcap_host_session_publish(ev.session, (const uint8_t *)"greeter", 7,
                        greet, NULL, NULL, &ref) == GLOWCAP_OK) published = 1;
                }
            }
            if (ev.kind == GLOWCAP_DRIVER_EVENT_OPEN_FAILED || ev.kind == GLOWCAP_DRIVER_EVENT_LISTENER_FAILED) goto done;
        }
        if (published && i > 1000) break;
    }
done:
    if (loop) glowcap_driver_release(loop, &failure);
    if (tcp) { glowcap_tcp_netlayer_shutdown(tcp); glowcap_tcp_netlayer_release(tcp); }
    return published ? 0 : 1;
}
