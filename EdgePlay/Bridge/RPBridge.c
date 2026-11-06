// SPDX-License-Identifier: AGPL-3.0-only

#include "RPBridge.h"

#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/opusencoder.h>
#include <chiaki/orientation.h>
#include <chiaki/time.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdio.h>
#include <sys/socket.h>

static ChiakiLog g_log;

int rp_global_init(void)
{
    // A send() on a socket the console has closed raises SIGPIPE, which silently
    // kills an iOS app. chiaki doesn't guard against it, so ignore it process-wide
    // and let the failed send return an error instead.
    signal(SIGPIPE, SIG_IGN);
    chiaki_log_init(&g_log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO, chiaki_log_cb_print, NULL);
    return chiaki_lib_init() == CHIAKI_ERR_SUCCESS ? 0 : -1;
}

// ============================================================== session

struct RPSession {
    ChiakiSession session;
    ChiakiLog log;
    ChiakiOpusDecoder opus;
    ChiakiControllerState pad;
    int8_t touch_ids[2];
    RPCallbacks cb;
    void *ctx;
    char *host;
    bool started;
    int32_t frames_lost_total;
    // motion
    ChiakiOrientationTracker orient;
    ChiakiAccelNewZero accel_zero;
    // microphone
    ChiakiOpusEncoder opus_enc;
    bool mic_connected;
    volatile bool connected;
    // haptics -> rumble
    uint8_t last_rumble_l, last_rumble_r;
    uint64_t last_rumble_ms;
};

static void session_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
    RPSession *s = user;
    if (s->cb.on_log)
        s->cb.on_log(s->ctx, (int)level, msg);
}

static void session_event_cb(ChiakiEvent *ev, void *user)
{
    RPSession *s = user;
    if (!s->cb.on_event)
        return;
    switch (ev->type) {
    case CHIAKI_EVENT_CONNECTED:
        s->connected = true;
        s->cb.on_event(s->ctx, RP_EVENT_CONNECTED, 0, false, NULL);
        break;
    case CHIAKI_EVENT_QUIT:
        s->cb.on_event(s->ctx, RP_EVENT_QUIT, (int32_t)ev->quit.reason,
                       chiaki_quit_reason_is_error(ev->quit.reason),
                       ev->quit.reason_str ? ev->quit.reason_str : chiaki_quit_reason_string(ev->quit.reason));
        break;
    case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
        s->cb.on_event(s->ctx, RP_EVENT_LOGIN_PIN_REQUEST, 0, ev->login_pin_request.pin_incorrect, NULL);
        break;
    case CHIAKI_EVENT_NICKNAME_RECEIVED: {
        char name[sizeof(ev->server_nickname) + 1];
        memcpy(name, ev->server_nickname, sizeof(ev->server_nickname));
        name[sizeof(ev->server_nickname)] = '\0';
        s->cb.on_event(s->ctx, RP_EVENT_NICKNAME, 0, false, name);
        break;
    }
    case CHIAKI_EVENT_RUMBLE:
        s->cb.on_event(s->ctx, RP_EVENT_RUMBLE, ((int32_t)ev->rumble.left << 8) | ev->rumble.right, false, NULL);
        break;
    case CHIAKI_EVENT_LED_COLOR:
        s->cb.on_event(s->ctx, RP_EVENT_LED_COLOR,
                       ((int32_t)ev->led_state[0] << 16) | ((int32_t)ev->led_state[1] << 8) | ev->led_state[2], false, NULL);
        break;
    default:
        break;
    }
}

static void session_event_cb_outer(ChiakiEvent *ev, void *user)
{
    RPSession *s = user;
    if (ev->type == CHIAKI_EVENT_QUIT)
        s->connected = false;
    if (ev->type == CHIAKI_EVENT_TRIGGER_EFFECTS) {
        if (s->cb.on_trigger_effects)
            s->cb.on_trigger_effects(s->ctx, ev->trigger_effects.type_left, ev->trigger_effects.left,
                                     ev->trigger_effects.type_right, ev->trigger_effects.right);
        return;
    }
    session_event_cb(ev, user);
}

static bool session_video_cb(uint8_t *buf, size_t size, int32_t frames_lost, bool recovered, void *user)
{
    RPSession *s = user;
    if (frames_lost > 0)
        s->frames_lost_total += frames_lost;
    if (!s->cb.on_video)
        return true;
    return s->cb.on_video(s->ctx, buf, size, frames_lost, recovered);
}

static void opus_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
    RPSession *s = user;
    if (s->cb.on_audio_format)
        s->cb.on_audio_format(s->ctx, channels, rate);
}

static void opus_frame_cb(int16_t *buf, size_t samples, void *user)
{
    RPSession *s = user;
    if (s->cb.on_audio_pcm)
        s->cb.on_audio_pcm(s->ctx, buf, samples);
}

/// PS5 sends DualSense haptics as a small audio stream (stereo int16, ~3 kHz) instead
/// of rumble events. iOS can't play HD haptics on a DualSense, so turn its envelope into
/// rumble strength per motor, like chiaki-ng does for non-DualSense pads.
static void haptics_frame_cb(uint8_t *buf, size_t buf_size, void *user)
{
    RPSession *s = user;
    if (!s->cb.on_event || buf_size < 4 || buf_size % 4 != 0)
        return;
    size_t n = buf_size / 4;
    uint32_t suml = 0, sumr = 0;
    int zcl = 0, zcr = 0;
    int16_t pl = 0, pr = 0;
    for (size_t i = 0; i < n; i++) {
        int16_t l, r;
        memcpy(&l, buf + i * 4, 2);
        memcpy(&r, buf + i * 4 + 2, 2);
        suml += (uint32_t)abs(l) * 2;
        sumr += (uint32_t)abs(r) * 2;
        if (i > 0) {
            if ((l >= 0) != (pl >= 0)) zcl++;
            if ((r >= 0) != (pr >= 0)) zcr++;
        }
        pl = l; pr = r;
    }
    uint32_t avl = suml / n, avr = sumr / n;
    if (avl < 100) avl = 0;      // same noise floor as chiaki-ng
    if (avr < 100) avr = 0;
    uint32_t L = avl * 3 > 65535 ? 65535 : avl * 3;
    uint32_t R = avr * 3 > 65535 ? 65535 : avr * 3;
    uint8_t l8 = (uint8_t)(L >> 8), r8 = (uint8_t)(R >> 8);

    // Pitch from zero crossings: the haptics stream runs at ~3 kHz, so in this frame
    // freq ~= crossings / 2 * (3000 / n). Map ~40 Hz .. ~320 Hz to sharpness 0..15.
    float fl = (float)zcl * 1500.0f / (float)n, fr = (float)zcr * 1500.0f / (float)n;
    int shl = (int)((fl - 40.0f) / 280.0f * 15.0f + 0.5f);
    int shr = (int)((fr - 40.0f) / 280.0f * 15.0f + 0.5f);
    shl = shl < 0 ? 0 : (shl > 15 ? 15 : shl);
    shr = shr < 0 ? 0 : (shr > 15 ? 15 : shr);

    uint64_t now = chiaki_time_now_monotonic_ms();
    int dl = (int)l8 - s->last_rumble_l, dr = (int)r8 - s->last_rumble_r;
    bool big_change = dl > 6 || dl < -6 || dr > 6 || dr < -6 || ((l8 | r8) == 0) != ((s->last_rumble_l | s->last_rumble_r) == 0);
    if (!big_change && now - s->last_rumble_ms < 40)
        return;
    if (!big_change && l8 == s->last_rumble_l && r8 == s->last_rumble_r && now - s->last_rumble_ms < 80)
        return;
    s->last_rumble_l = l8;
    s->last_rumble_r = r8;
    s->last_rumble_ms = now;
    // code: [sharpL:4][sharpR:4][left:8][right:8], left/right = controller sides
    int32_t code = (shl << 20) | (shr << 16) | ((int32_t)l8 << 8) | r8;
    s->cb.on_event(s->ctx, RP_EVENT_RUMBLE, code, true, NULL);
}

RPSession *rp_session_create(const RPConnectConfig *cfg, RPCallbacks callbacks, void *ctx, const char **err_out)
{
    if (err_out)
        *err_out = NULL;
    if (!cfg || !cfg->host) {
        if (err_out) *err_out = "No host";
        return NULL;
    }

    RPSession *s = calloc(1, sizeof(RPSession));
    if (!s) {
        if (err_out) *err_out = "Out of memory";
        return NULL;
    }
    s->cb = callbacks;
    s->ctx = ctx;
    s->touch_ids[0] = s->touch_ids[1] = -1;
    s->host = strdup(cfg->host);
    chiaki_controller_state_set_idle(&s->pad);

    chiaki_log_init(&s->log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO, session_log_cb, s);

    ChiakiConnectInfo info;
    memset(&info, 0, sizeof(info));
    info.ps5 = cfg->ps5;
    info.host = s->host;
    memcpy(info.regist_key, cfg->regist_key, sizeof(info.regist_key));
    memcpy(info.morning, cfg->morning, sizeof(info.morning));
    info.video_profile.width = cfg->width;
    info.video_profile.height = cfg->height;
    info.video_profile.max_fps = cfg->fps;
    info.video_profile.bitrate = cfg->bitrate_kbps;
    // PS4 only speaks H.264.
    info.video_profile.codec = cfg->ps5 ? (ChiakiCodec)cfg->codec : CHIAKI_CODEC_H264;
    info.video_profile_auto_downgrade = true;
    info.enable_keyboard = false;
    info.enable_dualsense = cfg->enable_dualsense;
    info.audio_video_disabled = CHIAKI_NONE_DISABLED;
    info.auto_regist = false;
    info.holepunch_session = NULL;
    info.rudp_sock = NULL;
    info.packet_loss_max = 0.05;
    info.enable_idr_on_fec_failure = true;

    ChiakiErrorCode err = chiaki_session_init(&s->session, &info, &s->log);
    if (err != CHIAKI_ERR_SUCCESS) {
        if (err_out) *err_out = chiaki_error_string(err);
        free(s->host);
        free(s);
        return NULL;
    }

    chiaki_session_set_event_cb(&s->session, session_event_cb_outer, s);
    chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);

    chiaki_opus_decoder_init(&s->opus, &s->log);
    chiaki_opus_decoder_set_cb(&s->opus, opus_settings_cb, opus_frame_cb, s);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&s->opus, &sink);
    chiaki_session_set_audio_sink(&s->session, &sink);

    if (cfg->enable_dualsense) {
        ChiakiAudioSink haptics;
        memset(&haptics, 0, sizeof(haptics));
        haptics.user = s;
        haptics.frame_cb = haptics_frame_cb;
        chiaki_session_set_haptics_sink(&s->session, &haptics);
    }

    // Motion
    chiaki_orientation_tracker_init(&s->orient);
    chiaki_accel_new_zero_set_inactive(&s->accel_zero, false);

    // Microphone: 48 kHz stereo, 10 ms frames (what chiaki-ng uses).
    chiaki_opus_encoder_init(&s->opus_enc, &s->log);
    ChiakiAudioHeader mic_header;
    chiaki_audio_header_set(&mic_header, 2, 16, RP_MIC_RATE, RP_MIC_FRAME_SAMPLES);
    chiaki_opus_encoder_header(&mic_header, &s->opus_enc, &s->session);

    return s;
}

int rp_session_start(RPSession *s)
{
    if (!s || s->started)
        return -1;
    ChiakiErrorCode err = chiaki_session_start(&s->session);
    if (err != CHIAKI_ERR_SUCCESS)
        return (int)err;
    s->started = true;
    return 0;
}

void rp_session_stop(RPSession *s)
{
    if (s && s->started)
        chiaki_session_stop(&s->session);
}

void rp_session_free(RPSession *s)
{
    if (!s)
        return;
    if (s->started) {
        chiaki_session_stop(&s->session);
        chiaki_session_join(&s->session);
    }
    chiaki_session_fini(&s->session);
    chiaki_opus_decoder_fini(&s->opus);
    chiaki_opus_encoder_fini(&s->opus_enc);
    free(s->host);
    free(s);
}

int rp_session_set_login_pin(RPSession *s, const char *pin)
{
    if (!s || !pin)
        return -1;
    return (int)chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

int rp_session_request_idr(RPSession *s)
{
    return s ? (int)chiaki_session_request_idr(&s->session) : -1;
}

int rp_session_sleep(RPSession *s)
{
    return s ? (int)chiaki_session_goto_bed(&s->session) : -1;
}

int rp_session_set_pad(RPSession *s, const RPPadState *p)
{
    if (!s || !p)
        return -1;
    ChiakiControllerState *st = &s->pad;
    st->buttons = p->buttons;
    st->l2_state = p->l2;
    st->r2_state = p->r2;
    st->left_x = p->left_x;
    st->left_y = p->left_y;
    st->right_x = p->right_x;
    st->right_y = p->right_y;

    for (int i = 0; i < 2; i++) {
        if (p->touch_active[i]) {
            if (s->touch_ids[i] < 0)
                s->touch_ids[i] = chiaki_controller_state_start_touch(st, p->touch_x[i], p->touch_y[i]);
            else
                chiaki_controller_state_set_touch_pos(st, (uint8_t)s->touch_ids[i], p->touch_x[i], p->touch_y[i]);
        } else if (s->touch_ids[i] >= 0) {
            chiaki_controller_state_stop_touch(st, (uint8_t)s->touch_ids[i]);
            s->touch_ids[i] = -1;
        }
    }

    if (p->has_motion) {
        // Same path chiaki-ng uses for SDL sensors: Madgwick filter -> orientation.
        chiaki_orientation_tracker_update(&s->orient, p->gyro_x, p->gyro_y, p->gyro_z,
                                          p->accel_x, p->accel_y, p->accel_z,
                                          &s->accel_zero, false, p->motion_timestamp_us);
        chiaki_orientation_tracker_apply_to_controller_state(&s->orient, st);
    }

    return (int)chiaki_session_set_controller_state(&s->session, st);
}

int rp_session_set_mic(RPSession *s, bool on)
{
    if (!s || !s->connected)
        return -1;   // the control channel only exists once the stream is up
    if (on && !s->mic_connected) {
        ChiakiErrorCode err = chiaki_session_connect_microphone(&s->session);
        if (err != CHIAKI_ERR_SUCCESS)
            return (int)err;
        s->mic_connected = true;
    }
    if (!s->mic_connected)
        return 0;
    // chiaki's flag reads "currently muted": true sends unmute.
    return (int)chiaki_session_toggle_microphone(&s->session, on);
}

void rp_session_push_mic(RPSession *s, const int16_t *pcm)
{
    if (!s || !pcm || !s->mic_connected || !s->connected)
        return;
    chiaki_opus_encoder_frame((int16_t *)pcm, &s->opus_enc);
}

void rp_session_get_stats(RPSession *s, RPStats *out)
{
    if (!out)
        return;
    memset(out, 0, sizeof(*out));
    if (!s)
        return;
    // Plain reads of values chiaki updates from its own threads; fine for a HUD.
    out->rtt_ms = (double)s->session.rtt_us / 1000.0;
    out->measured_mbps = s->session.stream_connection.measured_bitrate;
    out->packet_loss = s->session.stream_connection.congestion_control.packet_loss;
    out->frames_lost_total = s->frames_lost_total;
}

// ============================================================== registration

struct RPRegist {
    ChiakiRegist regist;
    ChiakiLog log;
    RPRegistCallback cb;
    void *ctx;
    bool started;
    char last_error[256];
};

static void regist_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
    RPRegist *r = user;
    if (level == CHIAKI_LOG_ERROR && msg)
        snprintf(r->last_error, sizeof(r->last_error), "%s", msg);
    chiaki_log_cb_print(level, msg, NULL);
}

static void regist_cb(ChiakiRegistEvent *ev, void *user)
{
    RPRegist *r = user;
    if (!r->cb)
        return;
    if (ev->type != CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS || !ev->registered_host) {
        const char *why = ev->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED ? "Cancelled"
                        : (r->last_error[0] ? r->last_error : NULL);
        r->cb(r->ctx, false, NULL, why);
        return;
    }
    ChiakiRegisteredHost *h = ev->registered_host;
    RPRegisteredHost out;
    memset(&out, 0, sizeof(out));
    out.ps5 = chiaki_target_is_ps5(h->target);
    memcpy(out.nickname, h->server_nickname, sizeof(out.nickname));
    out.nickname[sizeof(out.nickname) - 1] = '\0';
    memcpy(out.regist_key, h->rp_regist_key, RP_KEY_SIZE);
    memcpy(out.morning, h->rp_key, RP_KEY_SIZE);
    memcpy(out.mac, h->server_mac, sizeof(out.mac));
    r->cb(r->ctx, true, &out, NULL);
}

RPRegist *rp_regist_start(const char *host, bool ps5, const uint8_t account_id[RP_ACCOUNT_ID_SIZE],
                          uint32_t pin, RPRegistCallback cb, void *ctx)
{
    if (!host || !account_id)
        return NULL;
    RPRegist *r = calloc(1, sizeof(RPRegist));
    if (!r)
        return NULL;
    r->cb = cb;
    r->ctx = ctx;
    chiaki_log_init(&r->log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO, regist_log_cb, r);

    ChiakiRegistInfo info;
    memset(&info, 0, sizeof(info));
    info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
    info.host = host;            // chiaki_regist_start copies this
    info.broadcast = false;
    info.psn_online_id = NULL;   // use account id (required for PS4 >= 7.0 and all PS5)
    memcpy(info.psn_account_id, account_id, RP_ACCOUNT_ID_SIZE);
    info.pin = pin;
    info.console_pin = 0;
    info.holepunch_info = NULL;
    info.rudp = NULL;

    if (chiaki_regist_start(&r->regist, &r->log, &info, regist_cb, r) != CHIAKI_ERR_SUCCESS) {
        free(r);
        return NULL;
    }
    r->started = true;
    return r;
}

void rp_regist_cancel(RPRegist *r)
{
    if (r && r->started)
        chiaki_regist_stop(&r->regist);
}

void rp_regist_free(RPRegist *r)
{
    if (!r)
        return;
    if (r->started)
        chiaki_regist_fini(&r->regist);
    free(r);
}

// ============================================================== discovery & wake

struct RPProbe {
    ChiakiDiscoveryService service;
    ChiakiLog log;
    RPProbeCallback cb;
    void *ctx;
};

static void probe_cb(ChiakiDiscoveryHost *hosts, size_t count, void *user)
{
    RPProbe *p = user;
    if (!p->cb)
        return;
    if (count == 0) {
        p->cb(p->ctx, RP_HOST_UNKNOWN, false, NULL, NULL);
        return;
    }
    ChiakiDiscoveryHost *h = &hosts[0];
    RPHostState state = RP_HOST_UNKNOWN;
    if (h->state == CHIAKI_DISCOVERY_HOST_STATE_READY)
        state = RP_HOST_READY;
    else if (h->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY)
        state = RP_HOST_STANDBY;
    p->cb(p->ctx, state, chiaki_discovery_host_is_ps5(h), h->host_name, h->running_app_name);
}

RPProbe *rp_probe_start(const char *host, uint32_t interval_ms, RPProbeCallback cb, void *ctx)
{
    if (!host)
        return NULL;
    RPProbe *p = calloc(1, sizeof(RPProbe));
    if (!p)
        return NULL;
    p->cb = cb;
    p->ctx = ctx;
    chiaki_log_init(&p->log, CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING, chiaki_log_cb_print, NULL);

    // Family hint for name resolution; the service resolves send_host itself.
    struct sockaddr_storage addr;
    memset(&addr, 0, sizeof(addr));
    ((struct sockaddr_in *)&addr)->sin_family = AF_INET;

    ChiakiDiscoveryServiceOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.hosts_max = 1;
    opts.host_drop_pings = 3;
    opts.ping_ms = interval_ms ? interval_ms : 1500;
    opts.ping_initial_ms = 50;
    opts.send_addr = &addr;
    opts.send_addr_size = sizeof(struct sockaddr_in);
    opts.send_host = (char *)host;   // copied by the service
    opts.broadcast_addrs = NULL;
    opts.broadcast_num = 0;
    opts.cb = probe_cb;
    opts.cb_user = p;

    if (chiaki_discovery_service_init(&p->service, &opts, &p->log) != CHIAKI_ERR_SUCCESS) {
        free(p);
        return NULL;
    }
    return p;
}

void rp_probe_free(RPProbe *p)
{
    if (!p)
        return;
    chiaki_discovery_service_fini(&p->service);
    free(p);
}

int rp_wakeup(const char *host, const uint8_t regist_key[RP_KEY_SIZE], bool ps5)
{
    if (!host || !regist_key)
        return -1;
    // The wake credential is the regist key read as a hex string.
    char key[RP_KEY_SIZE + 1];
    memcpy(key, regist_key, RP_KEY_SIZE);
    key[RP_KEY_SIZE] = '\0';
    uint64_t credential = strtoull(key, NULL, 16);
    return (int)chiaki_discovery_wakeup(&g_log, NULL, host, credential, ps5);
}
