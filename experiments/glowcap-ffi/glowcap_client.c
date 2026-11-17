#include "glowcap_client.h"
#include "glowcap_driver.h"
#include "glowcap_net_transport_tcp.h"
#include "glowcap_ocapn.h"
#include <stdio.h>
#include <string.h>

static int fail_text(char *out, unsigned long cap, const char *where, int rc) {
    if (cap) snprintf(out, cap, "%s failed (%d)", where, rc);
    return rc ? rc : -1;
}

int nim_glowcap_greet(const char *uri, const char *name, char *out, unsigned long out_cap) {
    GlowcapHost *host = NULL;
    GlowcapDriverLoop *loop = NULL;
    GlowcapTcpNetlayer *tcp = NULL;
    GlowcapLocator *loc = NULL;
    GlowcapHostSession *session = NULL;
    GlowcapDriverFailure failure = { GLOWCAP_DRIVER_FAILURE_ABI_VERSION, sizeof failure };
    GlowcapDriverOptions options = {
        GLOWCAP_DRIVER_OPTIONS_ABI_VERSION, sizeof options,
        GLOWCAP_DRIVER_DEFAULT_WIRE_BUFFER_BYTES,
        GLOWCAP_DRIVER_DEFAULT_MAX_PENDING_OPENS,
        GLOWCAP_DRIVER_DEFAULT_HANDSHAKE_MS,
        GLOWCAP_DRIVER_DEFAULT_LISTENER_SETUP_MS,
        GLOWCAP_DRIVER_DEFAULT_SETTLE_MS,
        GLOWCAP_DRIVER_DEFAULT_BUSY_POLL_NS
    };
    GlowcapTcpConfig tcp_config = { { 0, 0, 0 }, GLOWCAP_TCP_PROFILE_TCP };
    unsigned char seed[64];
    uint64_t op = 0, fetch_vow = 0, call_vow = 0;
    int rc = GLOWCAP_OK;
    int result = -1;
    memset(seed, 0x5a, sizeof seed);
    memset(seed + 32, 0xa5, 32);
    if (!uri || !name || !out || !out_cap) return -1;

    rc = glowcap_host_new(seed, sizeof seed, GLOWCAP_DEFAULT_FRAME_CAP, 1,
                          GLOWCAP_CODEC_SYRUP, GLOWCAP_CAPTP_V1_0,
                          GLOWCAP_FEATURE_FULL, 0, 1, &host);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "host_new", rc);
    rc = glowcap_driver_take_host(host, &options, &loop);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "take_host", rc);
    host = NULL;
    rc = glowcap_tcp_netlayer_new(&tcp_config, &tcp);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "tcp_new", rc);
    GlowcapTransportProvider provider;
    rc = glowcap_tcp_transport_provider(tcp, &provider);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "tcp_provider", rc);
    rc = glowcap_driver_add_provider(loop, &provider, &failure);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "add_provider", rc);
    rc = glowcap_uri_parse_peer((const uint8_t *)uri, strlen(uri), &loc);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "parse_locator", rc);
    const GlowcapLocatorView *view = NULL;
    rc = glowcap_locator_borrow_view(loc, &view);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "locator_view", rc);
    rc = glowcap_driver_dial(loop, view, NULL, &op);
    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "dial", rc);

    for (unsigned step = 0; step < 20000; ++step) {
        rc = glowcap_driver_step(loop, 10);
        if (rc != GLOWCAP_OK && rc != GLOWCAP_ERR_WOULD_BLOCK)
            return fail_text(out, out_cap, "step", rc);
        GlowcapDriverEvent ev;
        while (glowcap_driver_next_event(loop, &ev) == GLOWCAP_OK) {
            if (ev.kind == GLOWCAP_DRIVER_EVENT_OPEN_FAILED)
                return fail_text(out, out_cap, "open", ev.primary_result);
            if (ev.kind == GLOWCAP_DRIVER_EVENT_OPENED) {
                session = ev.session;
                rc = glowcap_driver_claim_exporter_session(loop, session);
                if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "claim_session", rc);
                rc = glowcap_driver_session_serve(loop, session);
                if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "serve", rc);
                rc = glowcap_host_session_fetch(session, (const uint8_t *)name, strlen(name), &fetch_vow);
                if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "fetch", rc);
            } else if (ev.kind == GLOWCAP_DRIVER_EVENT_COMPLETION) {
                if (ev.action.ticket == fetch_vow && ev.action.kind == GLOWCAP_HOST_ACTION_SETTLE) {
                    if (ev.action.value.kind != GLOWCAP_ARG_REFERENCE)
                        return fail_text(out, out_cap, "fetch_not_reference", -1);
                    rc = glowcap_host_session_send(session, &ev.action.value.reference,
                        (const uint8_t *)"greet", 5,
                        &(GlowcapArgument){ .kind = GLOWCAP_ARG_STRING,
                          .bytes = (const uint8_t *)"world", .bytes_len = 5 },
                        1, &call_vow);
                    if (rc != GLOWCAP_OK) return fail_text(out, out_cap, "send", rc);
                } else if (ev.action.ticket == call_vow && ev.action.kind == GLOWCAP_HOST_ACTION_SETTLE) {
                    if (ev.action.value.kind != GLOWCAP_ARG_STRING)
                        return fail_text(out, out_cap, "reply_not_string", -1);
                    unsigned long n = ev.action.value.bytes_len;
                    if (n >= out_cap) n = out_cap - 1;
                    memcpy(out, ev.action.value.bytes, n); out[n] = 0;
                    result = (strcmp(out, "Hello, world") == 0) ? 0 : -2;
                    goto done;
                } else if (ev.action.kind == GLOWCAP_HOST_ACTION_FAIL) {
                    return fail_text(out, out_cap, "completion", ev.action.result);
                }
            }
        }
    }
    result = fail_text(out, out_cap, "timeout", GLOWCAP_ERR_TIMEOUT);
done:
    if (loc) glowcap_locator_release(loc);
    if (session) glowcap_driver_session_release(loop, session);
    if (loop) glowcap_driver_release(loop, &failure);
    if (tcp) { glowcap_tcp_netlayer_shutdown(tcp); glowcap_tcp_netlayer_release(tcp); }
    return result;
}
