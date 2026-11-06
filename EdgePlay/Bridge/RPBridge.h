// SPDX-License-Identifier: AGPL-3.0-only
//
// RPBridge — a small, flat C API over chiaki-ng so Swift never has to touch
// chiaki's large structs, unions or thread primitives directly.

#ifndef RP_BRIDGE_H
#define RP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_KEY_SIZE 16
#define RP_ACCOUNT_ID_SIZE 8

// ---------------------------------------------------------------- lifecycle

/// Call once at app launch. Returns 0 on success.
int rp_global_init(void);

// ---------------------------------------------------------------- session

typedef enum {
    RP_CODEC_H264 = 0,
    RP_CODEC_H265 = 1,
    RP_CODEC_H265_HDR = 2
} RPCodec;

typedef struct {
    const char *host;                 // IP, hostname, Tailscale IP or MagicDNS name
    bool ps5;
    uint8_t regist_key[RP_KEY_SIZE];  // from registration
    uint8_t morning[RP_KEY_SIZE];     // "rp_key" from registration
    uint32_t width;
    uint32_t height;
    uint32_t fps;
    uint32_t bitrate_kbps;
    RPCodec codec;
    bool enable_dualsense;
} RPConnectConfig;

typedef enum {
    RP_EVENT_CONNECTED = 0,
    RP_EVENT_QUIT = 1,             // code = chiaki quit reason, text = reason string, flag = is_error
    RP_EVENT_LOGIN_PIN_REQUEST = 2,// flag = previous pin was incorrect
    RP_EVENT_NICKNAME = 3,         // text = console nickname
    RP_EVENT_RUMBLE = 4,           // code = (left << 8) | right
    RP_EVENT_LED_COLOR = 5         // code = 0xRRGGBB
} RPEventType;

typedef struct {
    void (*on_event)(void *ctx, RPEventType type, int32_t code, bool flag, const char *text);
    /// Annex-B H.264/H.265 access unit. Return false if it could not be decoded
    /// (chiaki will then ask the console for a fresh keyframe).
    bool (*on_video)(void *ctx, const uint8_t *buf, size_t size, int32_t frames_lost, bool recovered);
    void (*on_audio_format)(void *ctx, uint32_t channels, uint32_t rate);
    /// Interleaved signed 16-bit PCM. sample_frames = samples per channel.
    void (*on_audio_pcm)(void *ctx, const int16_t *pcm, size_t sample_frames);
    void (*on_log)(void *ctx, int level, const char *msg);
    /// DualSense adaptive trigger effect, raw as the console sends it:
    /// effect type byte + 10 parameter bytes per trigger (DualSense output-report layout).
    void (*on_trigger_effects)(void *ctx, uint8_t type_left, const uint8_t *left10,
                               uint8_t type_right, const uint8_t *right10);
} RPCallbacks;

typedef struct RPSession RPSession;

/// Creates (but does not start) a session. Returns NULL on failure; *err gets chiaki's error string.
RPSession *rp_session_create(const RPConnectConfig *cfg, RPCallbacks callbacks, void *ctx, const char **err);
int rp_session_start(RPSession *s);
/// Asks the session to stop. Safe from any thread.
void rp_session_stop(RPSession *s);
/// Joins the session thread and frees everything. Call after stop, never from a callback.
void rp_session_free(RPSession *s);

int rp_session_set_login_pin(RPSession *s, const char *pin);
int rp_session_request_idr(RPSession *s);
/// Puts the console into rest mode.
int rp_session_sleep(RPSession *s);

// Controller ---------------------------------------------------------------

enum {
    RP_BTN_CROSS     = 1 << 0,
    RP_BTN_CIRCLE    = 1 << 1,
    RP_BTN_SQUARE    = 1 << 2,
    RP_BTN_TRIANGLE  = 1 << 3,
    RP_BTN_LEFT      = 1 << 4,
    RP_BTN_RIGHT     = 1 << 5,
    RP_BTN_UP        = 1 << 6,
    RP_BTN_DOWN      = 1 << 7,
    RP_BTN_L1        = 1 << 8,
    RP_BTN_R1        = 1 << 9,
    RP_BTN_L3        = 1 << 10,
    RP_BTN_R3        = 1 << 11,
    RP_BTN_OPTIONS   = 1 << 12,
    RP_BTN_SHARE     = 1 << 13,
    RP_BTN_TOUCHPAD  = 1 << 14,
    RP_BTN_PS        = 1 << 15
};

typedef struct {
    uint32_t buttons;
    uint8_t l2, r2;                       // 0..255
    int16_t left_x, left_y, right_x, right_y; // -32768..32767, +y = down (PlayStation convention)
    // Up to two touchpad fingers, coordinates in the 1920x942 touchpad space.
    bool touch_active[2];
    uint16_t touch_x[2], touch_y[2];
    // Motion (optional). Gyro rad/s, accel in g, orientation quaternion.
    bool has_motion;
    float gyro_x, gyro_y, gyro_z;
    float accel_x, accel_y, accel_z;
    float orient_x, orient_y, orient_z, orient_w;
} RPPadState;

int rp_session_set_pad(RPSession *s, const RPPadState *pad);

// Stats --------------------------------------------------------------------

typedef struct {
    double rtt_ms;
    double measured_mbps;     // what the console reports it is sending
    double packet_loss;       // 0..1, as seen by congestion control
    int32_t frames_lost_total;
} RPStats;

void rp_session_get_stats(RPSession *s, RPStats *out);

// ---------------------------------------------------------------- registration

typedef struct {
    bool ps5;
    char nickname[0x20];
    uint8_t regist_key[RP_KEY_SIZE];
    uint8_t morning[RP_KEY_SIZE];
    uint8_t mac[6];
} RPRegisteredHost;

typedef void (*RPRegistCallback)(void *ctx, bool success, const RPRegisteredHost *host);

typedef struct RPRegist RPRegist;

/// Pairs with a console. account_id is the 8-byte PSN account id (decode the base64 form first).
/// pin is the 8-digit code shown on the console under Remote Play > Link Device.
RPRegist *rp_regist_start(const char *host, bool ps5, const uint8_t account_id[RP_ACCOUNT_ID_SIZE],
                          uint32_t pin, RPRegistCallback cb, void *ctx);
void rp_regist_cancel(RPRegist *r);
void rp_regist_free(RPRegist *r);

// ---------------------------------------------------------------- discovery & wake

typedef enum {
    RP_HOST_UNKNOWN = 0,
    RP_HOST_READY = 1,
    RP_HOST_STANDBY = 2
} RPHostState;

typedef void (*RPProbeCallback)(void *ctx, RPHostState state, bool ps5,
                                const char *nickname, const char *running_app);

typedef struct RPProbe RPProbe;

/// Repeatedly pings one console by unicast (works over LAN, Tailscale and VPNs,
/// no multicast entitlement needed). Callback fires on every status change.
RPProbe *rp_probe_start(const char *host, uint32_t interval_ms, RPProbeCallback cb, void *ctx);
void rp_probe_free(RPProbe *p);

/// Sends a wake-from-rest packet. regist_key is the 16-byte key from registration.
int rp_wakeup(const char *host, const uint8_t regist_key[RP_KEY_SIZE], bool ps5);

#ifdef __cplusplus
}
#endif

#endif
