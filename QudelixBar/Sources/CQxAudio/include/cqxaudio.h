#ifndef CQXAUDIO_H
#define CQXAUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct QxAudio QxAudio;
typedef struct QxStream QxStream;

typedef struct {
    uint32_t id;
    char name[256];
    char description[256];
    char media_class[64];
    char device_api[32];
    char device_bus[32];
    char vendor_id[16];
    char product_id[16];
    char bluez_address[32];
} QxSinkInfo;

typedef struct {
    int valid;
    float volume;
    float channel_volume;
    int muted;
} QxSinkVolume;

typedef void (*QxChangeFn)(void *user);
typedef void (*QxCaptureFn)(void *user, const float *samples, uint32_t frames, uint32_t channels, uint32_t rate);
typedef void (*QxRenderFn)(void *user, const float *input, float *output, uint32_t frames, uint32_t channels, uint32_t rate);
typedef void (*QxToneFn)(void *user, float *output, uint32_t frames, uint32_t channels, uint32_t rate);

enum {
    QX_STREAM_CONNECTING = 0,
    QX_STREAM_STREAMING = 1,
    QX_STREAM_READY = 2,
    QX_STREAM_FAILED = -1
};

QxAudio *qx_audio_create(const char *app_name, int *error);
void qx_audio_destroy(QxAudio *audio);
int qx_audio_connected(QxAudio *audio);
void qx_audio_set_change_handler(QxAudio *audio, QxChangeFn fn, void *user);

int qx_audio_list_sinks(QxAudio *audio, QxSinkInfo *out, int max);
int qx_audio_get_default_sink(QxAudio *audio, int configured, char *out, size_t length);
int qx_audio_set_default_sink(QxAudio *audio, const char *name);
int qx_audio_get_force_rate(QxAudio *audio);
int qx_audio_set_force_rate(QxAudio *audio, int rate);
int qx_audio_get_sink_volume(QxAudio *audio, const char *node_name, QxSinkVolume *out);
int qx_audio_scale_sink_volume(QxAudio *audio, const char *node_name, float scale, int mute);

QxStream *qx_audio_start_monitor(QxAudio *audio, const char *sink_name, QxCaptureFn fn, void *user);
QxStream *qx_audio_start_insert(QxAudio *audio, const char *virtual_name, const char *virtual_description,
                                const char *target_sink, QxRenderFn fn, void *user);
QxStream *qx_audio_start_tone(QxAudio *audio, const char *sink_name, QxToneFn fn, void *user);

int qx_stream_state(QxStream *stream);
int qx_stream_leg_state(QxStream *stream, int leg);
uint32_t qx_stream_leg_rate(QxStream *stream, int leg);
uint32_t qx_stream_rate(QxStream *stream);
uint32_t qx_stream_channels(QxStream *stream);
uint64_t qx_stream_underruns(QxStream *stream);
uint64_t qx_stream_overruns(QxStream *stream);
void qx_stream_stop(QxStream *stream);

#ifdef __cplusplus
}
#endif

#endif
