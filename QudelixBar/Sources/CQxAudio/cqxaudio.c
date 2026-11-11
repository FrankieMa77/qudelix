#define _GNU_SOURCE
#include "cqxaudio.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>
#include <spa/utils/result.h>

#define QX_MAX_SINKS 64
#define QX_MAX_STREAMS 32
#define QX_NAME_MAX 256
#define QX_RING_FRAMES 16384
#define QX_RING_CHANNELS 2
#define QX_SCRATCH_FRAMES 8192
#define QX_SYNC_TIMEOUT_SECONDS 4
#define QX_WRITE_TIMEOUT_SECONDS 1
#define QX_MAX_CHANNELS 8
#define QX_DEFAULT_CLOCK_RATE 48000
#define QX_QUANTUM_FRAMES 512

typedef struct {
    int used;
    QxSinkInfo info;
    int device_id;
    QxSinkVolume volume;
    float channel_values[QX_MAX_CHANNELS];
    uint32_t channel_count;
    struct pw_node *node;
    struct spa_hook listener;
    QxAudio *audio;
} QxSinkSlot;

typedef struct {
    int used;
    uint32_t id;
    char api[32];
    char bus[32];
    char vendor_id[16];
    char product_id[16];
    char bluez_address[32];
    struct pw_device *device;
    struct spa_hook listener;
    QxAudio *audio;
} QxDeviceSlot;

typedef struct {
    QxStream *owner;
    struct pw_stream *stream;
    struct spa_hook listener;
    int role;
} QxLeg;

struct QxStream {
    QxAudio *audio;
    int kind;
    QxLeg legs[2];
    atomic_int state[2];
    atomic_uint rate[2];
    atomic_uint channels[2];
    QxCaptureFn capture_fn;
    QxRenderFn render_fn;
    QxToneFn tone_fn;
    void *user;
    float *ring;
    float *scratch_in;
    float *scratch_out;
    atomic_uint_fast64_t head;
    atomic_uint_fast64_t tail;
    atomic_int primed;
    atomic_uint_fast64_t underruns;
    atomic_uint_fast64_t overruns;
};

struct QxAudio {
    struct pw_thread_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct spa_hook core_listener;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    int pending;
    int done;
    int lost;
    QxSinkSlot sinks[QX_MAX_SINKS];
    QxDeviceSlot devices[QX_MAX_SINKS];
    struct pw_metadata *default_metadata;
    struct spa_hook default_listener;
    uint32_t default_metadata_id;
    struct pw_metadata *settings_metadata;
    struct spa_hook settings_listener;
    uint32_t settings_metadata_id;
    int clock_rate;
    char default_effective[QX_NAME_MAX];
    char default_configured[QX_NAME_MAX];
    int force_rate;
    QxStream *streams[QX_MAX_STREAMS];
    QxChangeFn change_fn;
    void *change_user;
};

static pthread_once_t qx_init_once = PTHREAD_ONCE_INIT;

static void qx_init(void)
{
    pw_init(NULL, NULL);
}

static void copy_string(char *dst, size_t length, const char *src)
{
    if (length == 0)
        return;
    if (src == NULL) {
        dst[0] = 0;
        return;
    }
    snprintf(dst, length, "%s", src);
}

static void notify(QxAudio *audio)
{
    if (audio->change_fn != NULL)
        audio->change_fn(audio->change_user);
}

static void core_done(void *data, uint32_t id, int seq)
{
    QxAudio *audio = data;
    if (id == PW_ID_CORE && seq == audio->pending) {
        audio->done = 1;
        pw_thread_loop_signal(audio->loop, false);
    }
}

static void core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
    QxAudio *audio = data;
    (void)seq;
    (void)message;
    if (id == PW_ID_CORE && (res == -EPIPE || res == -ECONNRESET)) {
        audio->lost = 1;
        pw_thread_loop_signal(audio->loop, false);
        notify(audio);
    }
}

static const struct pw_core_events core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = core_done,
    .error = core_error,
};

static int roundtrip_within(QxAudio *audio, int seconds)
{
    audio->done = 0;
    audio->pending = pw_core_sync(audio->core, PW_ID_CORE, audio->pending);
    int waited = 0;
    while (!audio->done) {
        if (audio->lost)
            return -1;
        if (pw_thread_loop_timed_wait(audio->loop, 1) != 0) {
            waited++;
            if (waited >= seconds)
                return -1;
        }
    }
    return 0;
}

static int roundtrip(QxAudio *audio)
{
    return roundtrip_within(audio, QX_SYNC_TIMEOUT_SECONDS);
}

static int roundtrip_write(QxAudio *audio)
{
    return roundtrip_within(audio, QX_WRITE_TIMEOUT_SECONDS);
}

static int json_name(const char *value, char *out, size_t length)
{
    out[0] = 0;
    if (value == NULL)
        return 0;
    const char *key = strstr(value, "\"name\"");
    if (key == NULL)
        return 0;
    const char *colon = strchr(key + 6, ':');
    if (colon == NULL)
        return 0;
    const char *open = strchr(colon, '"');
    if (open == NULL)
        return 0;
    open++;
    size_t n = 0;
    while (*open != 0 && *open != '"' && n + 1 < length) {
        if (*open == '\\' && open[1] != 0)
            open++;
        out[n++] = *open++;
    }
    out[n] = 0;
    return n > 0;
}

static int default_property(void *data, uint32_t subject, const char *key, const char *type, const char *value)
{
    QxAudio *audio = data;
    (void)type;
    if (subject != 0)
        return 0;
    if (key == NULL) {
        audio->default_effective[0] = 0;
        audio->default_configured[0] = 0;
    } else if (strcmp(key, "default.audio.sink") == 0) {
        json_name(value, audio->default_effective, sizeof audio->default_effective);
    } else if (strcmp(key, "default.configured.audio.sink") == 0) {
        json_name(value, audio->default_configured, sizeof audio->default_configured);
    } else {
        return 0;
    }
    notify(audio);
    return 0;
}

static int settings_property(void *data, uint32_t subject, const char *key, const char *type, const char *value)
{
    QxAudio *audio = data;
    (void)type;
    if (subject != 0)
        return 0;
    if (key == NULL) {
        audio->force_rate = 0;
        audio->clock_rate = 0;
    } else if (strcmp(key, "clock.force-rate") == 0) {
        audio->force_rate = value == NULL ? 0 : atoi(value);
    } else if (strcmp(key, "clock.rate") == 0) {
        audio->clock_rate = value == NULL ? 0 : atoi(value);
        return 0;
    } else {
        return 0;
    }
    notify(audio);
    return 0;
}

static const struct pw_metadata_events default_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = default_property,
};

static const struct pw_metadata_events settings_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = settings_property,
};

static void sink_param(void *data, int seq, uint32_t id, uint32_t index, uint32_t next, const struct spa_pod *param)
{
    QxSinkSlot *slot = data;
    (void)seq;
    (void)index;
    (void)next;
    if (id != SPA_PARAM_Props || param == NULL)
        return;
    float volume = 1.0f;
    bool mute = false;
    struct spa_pod *channel_volumes = NULL;
    struct spa_pod_parser parser;
    spa_pod_parser_pod(&parser, param);
    if (spa_pod_parser_get_object(&parser, SPA_TYPE_OBJECT_Props, NULL,
                                  SPA_PROP_volume, SPA_POD_OPT_Float(&volume),
                                  SPA_PROP_mute, SPA_POD_OPT_Bool(&mute),
                                  SPA_PROP_channelVolumes, SPA_POD_OPT_Pod(&channel_volumes)) < 0)
        return;
    float mean = volume;
    if (channel_volumes != NULL && spa_pod_is_array(channel_volumes)) {
        uint32_t count = 0;
        const float *values = spa_pod_get_array(channel_volumes, &count);
        if (values != NULL && count > 0 && SPA_POD_ARRAY_VALUE_TYPE(channel_volumes) == SPA_TYPE_Float) {
            float sum = 0;
            for (uint32_t i = 0; i < count; i++)
                sum += values[i];
            mean = sum / (float)count;
            slot->channel_count = count < QX_MAX_CHANNELS ? count : QX_MAX_CHANNELS;
            for (uint32_t i = 0; i < slot->channel_count; i++)
                slot->channel_values[i] = values[i];
        }
    }
    slot->volume.valid = 1;
    slot->volume.volume = volume;
    slot->volume.channel_volume = mean;
    slot->volume.muted = mute ? 1 : 0;
    notify(slot->audio);
}

static const char *lookup(const struct spa_dict *props, const char *key)
{
    return props == NULL ? NULL : spa_dict_lookup(props, key);
}

static void copy_present(char *dst, size_t length, const struct spa_dict *props, const char *key)
{
    const char *value = lookup(props, key);
    if (value != NULL)
        copy_string(dst, length, value);
}

static void sink_info(void *data, const struct pw_node_info *info)
{
    QxSinkSlot *slot = data;
    if (info == NULL || info->props == NULL || !(info->change_mask & PW_NODE_CHANGE_MASK_PROPS))
        return;
    const struct spa_dict *props = info->props;
    copy_present(slot->info.description, sizeof slot->info.description, props, PW_KEY_NODE_DESCRIPTION);
    copy_present(slot->info.device_api, sizeof slot->info.device_api, props, PW_KEY_DEVICE_API);
    copy_present(slot->info.device_bus, sizeof slot->info.device_bus, props, PW_KEY_DEVICE_BUS);
    copy_present(slot->info.vendor_id, sizeof slot->info.vendor_id, props, PW_KEY_DEVICE_VENDOR_ID);
    copy_present(slot->info.product_id, sizeof slot->info.product_id, props, PW_KEY_DEVICE_PRODUCT_ID);
    copy_present(slot->info.bluez_address, sizeof slot->info.bluez_address, props, "api.bluez5.address");
    const char *device = lookup(props, PW_KEY_DEVICE_ID);
    if (device != NULL)
        slot->device_id = atoi(device);
    notify(slot->audio);
}

static const struct pw_node_events sink_events = {
    PW_VERSION_NODE_EVENTS,
    .info = sink_info,
    .param = sink_param,
};

static void device_info(void *data, const struct pw_device_info *info)
{
    QxDeviceSlot *slot = data;
    if (info == NULL || info->props == NULL || !(info->change_mask & PW_DEVICE_CHANGE_MASK_PROPS))
        return;
    const struct spa_dict *props = info->props;
    copy_present(slot->api, sizeof slot->api, props, PW_KEY_DEVICE_API);
    copy_present(slot->bus, sizeof slot->bus, props, PW_KEY_DEVICE_BUS);
    copy_present(slot->vendor_id, sizeof slot->vendor_id, props, PW_KEY_DEVICE_VENDOR_ID);
    copy_present(slot->product_id, sizeof slot->product_id, props, PW_KEY_DEVICE_PRODUCT_ID);
    copy_present(slot->bluez_address, sizeof slot->bluez_address, props, "api.bluez5.address");
    notify(slot->audio);
}

static const struct pw_device_events device_events = {
    PW_VERSION_DEVICE_EVENTS,
    .info = device_info,
};

static void registry_global(void *data, uint32_t id, uint32_t permissions, const char *type,
                            uint32_t version, const struct spa_dict *props)
{
    QxAudio *audio = data;
    (void)permissions;
    (void)version;
    if (props == NULL)
        return;
    if (strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
        const char *media_class = lookup(props, PW_KEY_MEDIA_CLASS);
        if (media_class == NULL || strcmp(media_class, "Audio/Sink") != 0)
            return;
        QxSinkSlot *slot = NULL;
        for (int i = 0; i < QX_MAX_SINKS; i++) {
            if (audio->sinks[i].used && audio->sinks[i].info.id == id)
                return;
            if (slot == NULL && !audio->sinks[i].used)
                slot = &audio->sinks[i];
        }
        if (slot == NULL)
            return;
        memset(slot, 0, sizeof *slot);
        slot->used = 1;
        slot->audio = audio;
        slot->info.id = id;
        slot->device_id = -1;
        copy_string(slot->info.name, sizeof slot->info.name, lookup(props, PW_KEY_NODE_NAME));
        const char *description = lookup(props, PW_KEY_NODE_DESCRIPTION);
        if (description == NULL)
            description = lookup(props, PW_KEY_NODE_NICK);
        copy_string(slot->info.description, sizeof slot->info.description, description);
        copy_string(slot->info.media_class, sizeof slot->info.media_class, media_class);
        copy_string(slot->info.device_api, sizeof slot->info.device_api, lookup(props, PW_KEY_DEVICE_API));
        copy_string(slot->info.device_bus, sizeof slot->info.device_bus, lookup(props, PW_KEY_DEVICE_BUS));
        copy_string(slot->info.vendor_id, sizeof slot->info.vendor_id, lookup(props, PW_KEY_DEVICE_VENDOR_ID));
        copy_string(slot->info.product_id, sizeof slot->info.product_id, lookup(props, PW_KEY_DEVICE_PRODUCT_ID));
        copy_string(slot->info.bluez_address, sizeof slot->info.bluez_address, lookup(props, "api.bluez5.address"));
        slot->node = pw_registry_bind(audio->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
        if (slot->node != NULL) {
            pw_node_add_listener(slot->node, &slot->listener, &sink_events, slot);
            uint32_t ids[1] = { SPA_PARAM_Props };
            pw_node_subscribe_params(slot->node, ids, 1);
        }
        notify(audio);
    } else if (strcmp(type, PW_TYPE_INTERFACE_Device) == 0) {
        QxDeviceSlot *slot = NULL;
        for (int i = 0; i < QX_MAX_SINKS; i++) {
            if (audio->devices[i].used && audio->devices[i].id == id)
                return;
            if (slot == NULL && !audio->devices[i].used)
                slot = &audio->devices[i];
        }
        if (slot == NULL)
            return;
        memset(slot, 0, sizeof *slot);
        slot->used = 1;
        slot->audio = audio;
        slot->id = id;
        slot->device = pw_registry_bind(audio->registry, id, PW_TYPE_INTERFACE_Device, PW_VERSION_DEVICE, 0);
        if (slot->device != NULL)
            pw_device_add_listener(slot->device, &slot->listener, &device_events, slot);
    } else if (strcmp(type, PW_TYPE_INTERFACE_Metadata) == 0) {
        const char *name = lookup(props, PW_KEY_METADATA_NAME);
        if (name == NULL)
            return;
        if (strcmp(name, "default") == 0 && audio->default_metadata == NULL) {
            audio->default_metadata = pw_registry_bind(audio->registry, id, type, PW_VERSION_METADATA, 0);
            audio->default_metadata_id = id;
            if (audio->default_metadata != NULL)
                pw_metadata_add_listener(audio->default_metadata, &audio->default_listener, &default_events, audio);
        } else if (strcmp(name, "settings") == 0 && audio->settings_metadata == NULL) {
            audio->settings_metadata = pw_registry_bind(audio->registry, id, type, PW_VERSION_METADATA, 0);
            audio->settings_metadata_id = id;
            if (audio->settings_metadata != NULL)
                pw_metadata_add_listener(audio->settings_metadata, &audio->settings_listener, &settings_events, audio);
        }
    }
}

static void registry_global_remove(void *data, uint32_t id)
{
    QxAudio *audio = data;
    if (audio->default_metadata != NULL && audio->default_metadata_id == id) {
        spa_hook_remove(&audio->default_listener);
        pw_proxy_destroy((struct pw_proxy *)audio->default_metadata);
        audio->default_metadata = NULL;
        audio->default_effective[0] = 0;
        audio->default_configured[0] = 0;
        notify(audio);
        return;
    }
    if (audio->settings_metadata != NULL && audio->settings_metadata_id == id) {
        spa_hook_remove(&audio->settings_listener);
        pw_proxy_destroy((struct pw_proxy *)audio->settings_metadata);
        audio->settings_metadata = NULL;
        audio->force_rate = 0;
        audio->clock_rate = 0;
        notify(audio);
        return;
    }
    for (int i = 0; i < QX_MAX_SINKS; i++) {
        QxSinkSlot *slot = &audio->sinks[i];
        if (slot->used && slot->info.id == id) {
            if (slot->node != NULL) {
                spa_hook_remove(&slot->listener);
                pw_proxy_destroy((struct pw_proxy *)slot->node);
            }
            memset(slot, 0, sizeof *slot);
            notify(audio);
            return;
        }
    }
    for (int i = 0; i < QX_MAX_SINKS; i++) {
        QxDeviceSlot *slot = &audio->devices[i];
        if (slot->used && slot->id == id) {
            if (slot->device != NULL) {
                spa_hook_remove(&slot->listener);
                pw_proxy_destroy((struct pw_proxy *)slot->device);
            }
            memset(slot, 0, sizeof *slot);
            notify(audio);
            return;
        }
    }
}

static const struct pw_registry_events registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = registry_global,
    .global_remove = registry_global_remove,
};

QxAudio *qx_audio_create(const char *app_name, int *error)
{
    pthread_once(&qx_init_once, qx_init);
    int err = 0;
    QxAudio *audio = calloc(1, sizeof *audio);
    if (audio == NULL) {
        if (error != NULL)
            *error = ENOMEM;
        return NULL;
    }
    audio->loop = pw_thread_loop_new("qudelix-audio", NULL);
    if (audio->loop == NULL) {
        err = errno != 0 ? errno : ENOMEM;
        goto fail;
    }
    audio->context = pw_context_new(pw_thread_loop_get_loop(audio->loop),
                                    pw_properties_new(PW_KEY_APP_NAME, app_name != NULL ? app_name : "Qudelix", NULL), 0);
    if (audio->context == NULL) {
        err = errno != 0 ? errno : ENOMEM;
        goto fail;
    }
    if (pw_thread_loop_start(audio->loop) < 0) {
        err = errno != 0 ? errno : EIO;
        goto fail;
    }
    pw_thread_loop_lock(audio->loop);
    audio->core = pw_context_connect(audio->context, NULL, 0);
    if (audio->core == NULL) {
        err = errno != 0 ? errno : ECONNREFUSED;
        pw_thread_loop_unlock(audio->loop);
        goto fail;
    }
    pw_core_add_listener(audio->core, &audio->core_listener, &core_events, audio);
    audio->registry = pw_core_get_registry(audio->core, PW_VERSION_REGISTRY, 0);
    pw_registry_add_listener(audio->registry, &audio->registry_listener, &registry_events, audio);
    int ok = roundtrip(audio) == 0 && roundtrip(audio) == 0 && roundtrip(audio) == 0;
    pw_thread_loop_unlock(audio->loop);
    if (!ok) {
        err = ETIMEDOUT;
        goto fail;
    }
    if (error != NULL)
        *error = 0;
    return audio;

fail:
    if (error != NULL)
        *error = err;
    qx_audio_destroy(audio);
    return NULL;
}

static void destroy_stream_locked(QxStream *stream);

void qx_audio_destroy(QxAudio *audio)
{
    if (audio == NULL)
        return;
    if (audio->loop != NULL && audio->core != NULL) {
        pw_thread_loop_lock(audio->loop);
        for (int i = 0; i < QX_MAX_STREAMS; i++) {
            if (audio->streams[i] != NULL)
                destroy_stream_locked(audio->streams[i]);
        }
        audio->change_fn = NULL;
        for (int i = 0; i < QX_MAX_SINKS; i++) {
            QxSinkSlot *slot = &audio->sinks[i];
            if (slot->used && slot->node != NULL) {
                spa_hook_remove(&slot->listener);
                pw_proxy_destroy((struct pw_proxy *)slot->node);
            }
        }
        for (int i = 0; i < QX_MAX_SINKS; i++) {
            QxDeviceSlot *slot = &audio->devices[i];
            if (slot->used && slot->device != NULL) {
                spa_hook_remove(&slot->listener);
                pw_proxy_destroy((struct pw_proxy *)slot->device);
            }
        }
        if (audio->default_metadata != NULL) {
            spa_hook_remove(&audio->default_listener);
            pw_proxy_destroy((struct pw_proxy *)audio->default_metadata);
        }
        if (audio->settings_metadata != NULL) {
            spa_hook_remove(&audio->settings_listener);
            pw_proxy_destroy((struct pw_proxy *)audio->settings_metadata);
        }
        if (audio->registry != NULL) {
            spa_hook_remove(&audio->registry_listener);
            pw_proxy_destroy((struct pw_proxy *)audio->registry);
        }
        spa_hook_remove(&audio->core_listener);
        pw_core_disconnect(audio->core);
        pw_thread_loop_unlock(audio->loop);
    }
    if (audio->loop != NULL)
        pw_thread_loop_stop(audio->loop);
    if (audio->context != NULL)
        pw_context_destroy(audio->context);
    if (audio->loop != NULL)
        pw_thread_loop_destroy(audio->loop);
    free(audio);
}

int qx_audio_connected(QxAudio *audio)
{
    pw_thread_loop_lock(audio->loop);
    int connected = !audio->lost;
    pw_thread_loop_unlock(audio->loop);
    return connected;
}

void qx_audio_set_change_handler(QxAudio *audio, QxChangeFn fn, void *user)
{
    pw_thread_loop_lock(audio->loop);
    audio->change_fn = fn;
    audio->change_user = user;
    pw_thread_loop_unlock(audio->loop);
}

int qx_audio_list_sinks(QxAudio *audio, QxSinkInfo *out, int max)
{
    int count = 0;
    pw_thread_loop_lock(audio->loop);
    for (int i = 0; i < QX_MAX_SINKS && count < max; i++) {
        const QxSinkSlot *slot = &audio->sinks[i];
        if (!slot->used)
            continue;
        QxSinkInfo info = slot->info;
        for (int d = 0; d < QX_MAX_SINKS && slot->device_id >= 0; d++) {
            const QxDeviceSlot *device = &audio->devices[d];
            if (!device->used || device->id != (uint32_t)slot->device_id)
                continue;
            if (info.device_api[0] == 0)
                copy_string(info.device_api, sizeof info.device_api, device->api);
            if (info.device_bus[0] == 0)
                copy_string(info.device_bus, sizeof info.device_bus, device->bus);
            if (info.vendor_id[0] == 0)
                copy_string(info.vendor_id, sizeof info.vendor_id, device->vendor_id);
            if (info.product_id[0] == 0)
                copy_string(info.product_id, sizeof info.product_id, device->product_id);
            if (info.bluez_address[0] == 0)
                copy_string(info.bluez_address, sizeof info.bluez_address, device->bluez_address);
            break;
        }
        out[count++] = info;
    }
    pw_thread_loop_unlock(audio->loop);
    return count;
}

int qx_audio_get_default_sink(QxAudio *audio, int configured, char *out, size_t length)
{
    pw_thread_loop_lock(audio->loop);
    const char *value = configured ? audio->default_configured : audio->default_effective;
    copy_string(out, length, value);
    int present = value[0] != 0;
    pw_thread_loop_unlock(audio->loop);
    return present;
}

int qx_audio_set_default_sink(QxAudio *audio, const char *name)
{
    if (name != NULL && (strchr(name, '"') != NULL || strchr(name, '\\') != NULL || name[0] == 0))
        return -EINVAL;
    pw_thread_loop_lock(audio->loop);
    int result = -ENOTCONN;
    if (audio->default_metadata != NULL && !audio->lost) {
        if (name == NULL) {
            result = pw_metadata_set_property(audio->default_metadata, 0, "default.configured.audio.sink", NULL, NULL);
        } else {
            char json[QX_NAME_MAX + 16];
            snprintf(json, sizeof json, "{\"name\":\"%s\"}", name);
            result = pw_metadata_set_property(audio->default_metadata, 0, "default.configured.audio.sink",
                                              "Spa:String:JSON", json);
        }
        if (result >= 0)
            result = roundtrip_write(audio);
    }
    pw_thread_loop_unlock(audio->loop);
    return result;
}

int qx_audio_get_force_rate(QxAudio *audio)
{
    pw_thread_loop_lock(audio->loop);
    int rate = audio->force_rate;
    pw_thread_loop_unlock(audio->loop);
    return rate;
}

int qx_audio_set_force_rate(QxAudio *audio, int rate)
{
    if (rate < 0)
        return -EINVAL;
    pw_thread_loop_lock(audio->loop);
    int result = -ENOTCONN;
    if (audio->settings_metadata != NULL && !audio->lost) {
        char text[16];
        snprintf(text, sizeof text, "%d", rate);
        result = pw_metadata_set_property(audio->settings_metadata, 0, "clock.force-rate", "Spa:String:JSON", text);
        if (result >= 0)
            result = roundtrip_write(audio);
    }
    pw_thread_loop_unlock(audio->loop);
    return result;
}

int qx_audio_get_sink_volume(QxAudio *audio, const char *node_name, QxSinkVolume *out)
{
    int found = 0;
    memset(out, 0, sizeof *out);
    pw_thread_loop_lock(audio->loop);
    for (int i = 0; i < QX_MAX_SINKS; i++) {
        if (audio->sinks[i].used && strcmp(audio->sinks[i].info.name, node_name) == 0) {
            *out = audio->sinks[i].volume;
            found = out->valid;
            break;
        }
    }
    pw_thread_loop_unlock(audio->loop);
    return found;
}

int qx_audio_scale_sink_volume(QxAudio *audio, const char *node_name, float scale, int mute)
{
    if (!(scale >= 0.0f) || scale > 16.0f)
        return -EINVAL;
    pw_thread_loop_lock(audio->loop);
    int result = -ENOTCONN;
    if (!audio->lost) {
        result = -ENOENT;
        for (int i = 0; i < QX_MAX_SINKS; i++) {
            QxSinkSlot *slot = &audio->sinks[i];
            if (!slot->used || strcmp(slot->info.name, node_name) != 0)
                continue;
            if (slot->node == NULL || !slot->volume.valid || slot->channel_count == 0)
                break;
            float values[QX_MAX_CHANNELS];
            for (uint32_t c = 0; c < slot->channel_count; c++)
                values[c] = slot->channel_values[c] * scale;
            uint8_t buffer[512];
            struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
            struct spa_pod *pod;
            if (mute >= 0) {
                pod = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
                    SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, slot->channel_count, values),
                    SPA_PROP_mute, SPA_POD_Bool(mute != 0));
            } else {
                pod = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props,
                    SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, slot->channel_count, values));
            }
            result = pw_node_set_param(slot->node, SPA_PARAM_Props, 0, pod);
            if (result >= 0)
                result = roundtrip_write(audio);
            break;
        }
    }
    pw_thread_loop_unlock(audio->loop);
    return result;
}

enum {
    KIND_MONITOR = 0,
    KIND_INSERT = 1,
    KIND_TONE = 2
};

static void leg_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error)
{
    QxLeg *leg = data;
    (void)old;
    (void)error;
    int mapped = QX_STREAM_CONNECTING;
    if (state == PW_STREAM_STATE_STREAMING)
        mapped = QX_STREAM_STREAMING;
    else if (state == PW_STREAM_STATE_PAUSED)
        mapped = QX_STREAM_READY;
    else if (state == PW_STREAM_STATE_ERROR)
        mapped = QX_STREAM_FAILED;
    atomic_store(&leg->owner->state[leg->role], mapped);
}

static void leg_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
    QxLeg *leg = data;
    if (id != SPA_PARAM_Format || param == NULL)
        return;
    struct spa_audio_info_raw info;
    memset(&info, 0, sizeof info);
    if (spa_format_audio_raw_parse(param, &info) < 0)
        return;
    atomic_store(&leg->owner->rate[leg->role], info.rate);
    atomic_store(&leg->owner->channels[leg->role], info.channels);
}

static void ring_push(QxStream *stream, const float *samples, uint32_t frames)
{
    uint64_t head = atomic_load_explicit(&stream->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&stream->tail, memory_order_acquire);
    uint64_t room = QX_RING_FRAMES - (head - tail);
    if (frames > room) {
        atomic_fetch_add_explicit(&stream->overruns, 1, memory_order_relaxed);
        frames = (uint32_t)room;
    }
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t index = ((head + i) & (QX_RING_FRAMES - 1)) * QX_RING_CHANNELS;
        stream->ring[index] = samples[i * 2];
        stream->ring[index + 1] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&stream->head, head + frames, memory_order_release);
}

static uint32_t ring_pop(QxStream *stream, float *out, uint32_t frames)
{
    uint64_t tail = atomic_load_explicit(&stream->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&stream->head, memory_order_acquire);
    uint64_t fill = head - tail;
    uint64_t limit = 4 * (uint64_t)frames;
    if (limit < 2048)
        limit = 2048;
    if (fill > limit) {
        tail = head - 2 * (uint64_t)frames;
        fill = 2 * (uint64_t)frames;
        atomic_fetch_add_explicit(&stream->overruns, 1, memory_order_relaxed);
    }
    if (!atomic_load_explicit(&stream->primed, memory_order_relaxed)) {
        if (fill < 2 * (uint64_t)frames) {
            atomic_store_explicit(&stream->tail, tail, memory_order_release);
            return 0;
        }
        atomic_store_explicit(&stream->primed, 1, memory_order_relaxed);
    }
    uint32_t take = fill < frames ? (uint32_t)fill : frames;
    for (uint32_t i = 0; i < take; i++) {
        uint64_t index = ((tail + i) & (QX_RING_FRAMES - 1)) * QX_RING_CHANNELS;
        out[i * 2] = stream->ring[index];
        out[i * 2 + 1] = stream->ring[index + 1];
    }
    atomic_store_explicit(&stream->tail, tail + take, memory_order_release);
    if (take < frames) {
        atomic_fetch_add_explicit(&stream->underruns, 1, memory_order_relaxed);
        atomic_store_explicit(&stream->primed, 0, memory_order_relaxed);
    }
    return take;
}

static void monitor_process(void *data)
{
    QxLeg *leg = data;
    QxStream *stream = leg->owner;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(leg->stream);
    if (buffer == NULL)
        return;
    struct spa_data *d = &buffer->buffer->datas[0];
    uint32_t channels = atomic_load_explicit(&stream->channels[0], memory_order_relaxed);
    uint32_t rate = atomic_load_explicit(&stream->rate[0], memory_order_relaxed);
    if (d->data != NULL && channels > 0) {
        uint32_t stride = channels * (uint32_t)sizeof(float);
        uint32_t offset = SPA_MIN(d->chunk->offset, d->maxsize);
        uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - offset);
        uint32_t frames = size / stride;
        if (frames > 0 && stream->capture_fn != NULL)
            stream->capture_fn(stream->user, (const float *)SPA_PTROFF(d->data, offset, void), frames, channels, rate);
    }
    pw_stream_queue_buffer(leg->stream, buffer);
}

static void sink_process(void *data)
{
    QxLeg *leg = data;
    QxStream *stream = leg->owner;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(leg->stream);
    if (buffer == NULL)
        return;
    struct spa_data *d = &buffer->buffer->datas[0];
    uint32_t channels = atomic_load_explicit(&stream->channels[0], memory_order_relaxed);
    if (d->data != NULL && channels == QX_RING_CHANNELS) {
        uint32_t stride = channels * (uint32_t)sizeof(float);
        uint32_t offset = SPA_MIN(d->chunk->offset, d->maxsize);
        uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - offset);
        uint32_t frames = size / stride;
        if (frames > 0)
            ring_push(stream, (const float *)SPA_PTROFF(d->data, offset, void), frames);
    }
    pw_stream_queue_buffer(leg->stream, buffer);
}

static void playback_process(void *data)
{
    QxLeg *leg = data;
    QxStream *stream = leg->owner;
    struct pw_buffer *buffer = pw_stream_dequeue_buffer(leg->stream);
    if (buffer == NULL)
        return;
    struct spa_data *d = &buffer->buffer->datas[0];
    uint32_t channels = atomic_load_explicit(&stream->channels[1], memory_order_relaxed);
    uint32_t rate = atomic_load_explicit(&stream->rate[1], memory_order_relaxed);
    if (d->data == NULL || channels == 0) {
        pw_stream_queue_buffer(leg->stream, buffer);
        return;
    }
    uint32_t stride = channels * (uint32_t)sizeof(float);
    uint32_t frames = d->maxsize / stride;
    if (buffer->requested > 0 && buffer->requested < frames)
        frames = (uint32_t)buffer->requested;
    if (frames > QX_SCRATCH_FRAMES)
        frames = QX_SCRATCH_FRAMES;
    float *out = (float *)d->data;
    if (stream->kind == KIND_TONE) {
        if (stream->tone_fn != NULL)
            stream->tone_fn(stream->user, out, frames, channels, rate);
    } else if (channels == QX_RING_CHANNELS) {
        uint32_t got = ring_pop(stream, stream->scratch_in, frames);
        if (got < frames)
            memset(stream->scratch_in + got * 2, 0, (frames - got) * 2 * sizeof(float));
        if (stream->render_fn != NULL)
            stream->render_fn(stream->user, stream->scratch_in, out, frames, channels, rate);
        else
            memcpy(out, stream->scratch_in, frames * stride);
    } else {
        memset(out, 0, frames * stride);
    }
    d->chunk->offset = 0;
    d->chunk->stride = (int32_t)stride;
    d->chunk->size = frames * stride;
    pw_stream_queue_buffer(leg->stream, buffer);
}

static const struct pw_stream_events monitor_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = leg_state_changed,
    .param_changed = leg_param_changed,
    .process = monitor_process,
};

static const struct pw_stream_events sink_leg_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = leg_state_changed,
    .param_changed = leg_param_changed,
    .process = sink_process,
};

static const struct pw_stream_events playback_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = leg_state_changed,
    .param_changed = leg_param_changed,
    .process = playback_process,
};

static int connect_leg(QxStream *stream, int role, struct pw_properties *props, const struct pw_stream_events *events,
                       enum pw_direction direction, enum pw_stream_flags flags)
{
    QxLeg *leg = &stream->legs[role];
    leg->owner = stream;
    leg->role = role;
    atomic_store(&stream->state[role], QX_STREAM_CONNECTING);
    leg->stream = pw_stream_new(stream->audio->core, "qudelix", props);
    if (leg->stream == NULL)
        return -errno;
    pw_stream_add_listener(leg->stream, &leg->listener, events, leg);
    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof buffer);
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .channels = 2);
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info);
    int result = pw_stream_connect(leg->stream, direction, PW_ID_ANY, flags, params, 1);
    if (result < 0) {
        spa_hook_remove(&leg->listener);
        pw_stream_destroy(leg->stream);
        leg->stream = NULL;
    }
    return result;
}

static void destroy_stream_locked(QxStream *stream)
{
    for (int i = 0; i < QX_MAX_STREAMS; i++) {
        if (stream->audio->streams[i] == stream)
            stream->audio->streams[i] = NULL;
    }
    for (int role = 0; role < 2; role++) {
        QxLeg *leg = &stream->legs[role];
        if (leg->stream != NULL) {
            spa_hook_remove(&leg->listener);
            pw_stream_destroy(leg->stream);
            leg->stream = NULL;
        }
    }
    free(stream->ring);
    free(stream->scratch_in);
    free(stream->scratch_out);
    free(stream);
}

static QxStream *stream_alloc(QxAudio *audio, int kind)
{
    QxStream *stream = calloc(1, sizeof *stream);
    if (stream == NULL)
        return NULL;
    stream->audio = audio;
    stream->kind = kind;
    if (kind == KIND_INSERT) {
        stream->ring = calloc((size_t)QX_RING_FRAMES * QX_RING_CHANNELS, sizeof(float));
        stream->scratch_in = calloc((size_t)QX_SCRATCH_FRAMES * QX_RING_CHANNELS, sizeof(float));
        stream->scratch_out = calloc((size_t)QX_SCRATCH_FRAMES * QX_RING_CHANNELS, sizeof(float));
        if (stream->ring == NULL || stream->scratch_in == NULL || stream->scratch_out == NULL) {
            free(stream->ring);
            free(stream->scratch_in);
            free(stream->scratch_out);
            free(stream);
            return NULL;
        }
    }
    return stream;
}

static int register_stream(QxAudio *audio, QxStream *stream)
{
    for (int i = 0; i < QX_MAX_STREAMS; i++) {
        if (audio->streams[i] == NULL) {
            audio->streams[i] = stream;
            return 1;
        }
    }
    return 0;
}

static void latency_text(QxAudio *audio, char *out, size_t length)
{
    int rate = audio->force_rate > 0 ? audio->force_rate : audio->clock_rate;
    if (rate <= 0)
        rate = QX_DEFAULT_CLOCK_RATE;
    snprintf(out, length, "%d/%d", QX_QUANTUM_FRAMES, rate);
}

static QxStream *finish_start(QxAudio *audio, QxStream *stream, int result)
{
    if (result < 0 || !register_stream(audio, stream)) {
        destroy_stream_locked(stream);
        return NULL;
    }
    return stream;
}

QxStream *qx_audio_start_monitor(QxAudio *audio, const char *sink_name, QxCaptureFn fn, void *user)
{
    pw_thread_loop_lock(audio->loop);
    QxStream *stream = audio->lost ? NULL : stream_alloc(audio, KIND_MONITOR);
    if (stream == NULL) {
        pw_thread_loop_unlock(audio->loop);
        return NULL;
    }
    stream->capture_fn = fn;
    stream->user = user;
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_ROLE, "Production",
        PW_KEY_NODE_NAME, "qudelix_monitor",
        PW_KEY_NODE_DESCRIPTION, "Qudelix Monitor",
        PW_KEY_STREAM_CAPTURE_SINK, "true",
        PW_KEY_TARGET_OBJECT, sink_name,
        "node.dont-fallback", "true",
        NULL);
    int result = connect_leg(stream, 0, props, &monitor_events, PW_DIRECTION_INPUT,
                             PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS);
    stream = finish_start(audio, stream, result);
    pw_thread_loop_unlock(audio->loop);
    return stream;
}

QxStream *qx_audio_start_insert(QxAudio *audio, const char *virtual_name, const char *virtual_description,
                                const char *target_sink, QxRenderFn fn, void *user)
{
    pw_thread_loop_lock(audio->loop);
    QxStream *stream = audio->lost ? NULL : stream_alloc(audio, KIND_INSERT);
    if (stream == NULL) {
        pw_thread_loop_unlock(audio->loop);
        return NULL;
    }
    stream->render_fn = fn;
    stream->user = user;
    char latency[32];
    latency_text(audio, latency, sizeof latency);
    struct pw_properties *sink_props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Capture",
        PW_KEY_MEDIA_CLASS, "Audio/Sink",
        PW_KEY_NODE_NAME, virtual_name,
        PW_KEY_NODE_DESCRIPTION, virtual_description,
        PW_KEY_NODE_VIRTUAL, "true",
        PW_KEY_NODE_LATENCY, latency,
        NULL);
    int result = connect_leg(stream, 0, sink_props, &sink_leg_events, PW_DIRECTION_INPUT,
                             PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS);
    if (result >= 0) {
        struct pw_properties *play_props = pw_properties_new(
            PW_KEY_MEDIA_TYPE, "Audio",
            PW_KEY_MEDIA_CATEGORY, "Playback",
            PW_KEY_MEDIA_ROLE, "Music",
            PW_KEY_NODE_NAME, "qudelix_stage_output",
            PW_KEY_NODE_DESCRIPTION, "Qudelix Stage Output",
            PW_KEY_TARGET_OBJECT, target_sink,
            PW_KEY_NODE_LATENCY, latency,
            "node.dont-fallback", "true",
            "node.dont-reconnect", "true",
            NULL);
        result = connect_leg(stream, 1, play_props, &playback_events, PW_DIRECTION_OUTPUT,
                             PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS);
    }
    stream = finish_start(audio, stream, result);
    pw_thread_loop_unlock(audio->loop);
    return stream;
}

QxStream *qx_audio_start_tone(QxAudio *audio, const char *sink_name, QxToneFn fn, void *user)
{
    pw_thread_loop_lock(audio->loop);
    QxStream *stream = audio->lost ? NULL : stream_alloc(audio, KIND_TONE);
    if (stream == NULL) {
        pw_thread_loop_unlock(audio->loop);
        return NULL;
    }
    stream->tone_fn = fn;
    stream->user = user;
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Music",
        PW_KEY_NODE_NAME, "qudelix_tone",
        PW_KEY_NODE_DESCRIPTION, "Qudelix Tone",
        PW_KEY_TARGET_OBJECT, sink_name,
        "node.dont-fallback", "true",
        NULL);
    int result = connect_leg(stream, 1, props, &playback_events, PW_DIRECTION_OUTPUT,
                             PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS);
    stream = finish_start(audio, stream, result);
    pw_thread_loop_unlock(audio->loop);
    return stream;
}

int qx_stream_state(QxStream *stream)
{
    int state = QX_STREAM_STREAMING;
    int legs = stream->kind == KIND_INSERT ? 2 : 1;
    int first = stream->kind == KIND_TONE ? 1 : 0;
    for (int i = first; i < first + legs; i++) {
        int s = atomic_load(&stream->state[i]);
        if (s == QX_STREAM_FAILED)
            return QX_STREAM_FAILED;
        if (s == QX_STREAM_CONNECTING)
            return QX_STREAM_CONNECTING;
        if (s == QX_STREAM_READY)
            state = QX_STREAM_READY;
    }
    return state;
}

int qx_stream_leg_state(QxStream *stream, int leg)
{
    if (leg < 0 || leg > 1)
        return QX_STREAM_CONNECTING;
    return atomic_load(&stream->state[leg]);
}

uint32_t qx_stream_leg_rate(QxStream *stream, int leg)
{
    if (leg < 0 || leg > 1)
        return 0;
    return atomic_load(&stream->rate[leg]);
}

uint32_t qx_stream_rate(QxStream *stream)
{
    return atomic_load(&stream->rate[stream->kind == KIND_MONITOR ? 0 : 1]);
}

uint32_t qx_stream_channels(QxStream *stream)
{
    return atomic_load(&stream->channels[stream->kind == KIND_MONITOR ? 0 : 1]);
}

uint64_t qx_stream_underruns(QxStream *stream)
{
    return atomic_load(&stream->underruns);
}

uint64_t qx_stream_overruns(QxStream *stream)
{
    return atomic_load(&stream->overruns);
}

void qx_stream_stop(QxStream *stream)
{
    if (stream == NULL)
        return;
    QxAudio *audio = stream->audio;
    pw_thread_loop_lock(audio->loop);
    destroy_stream_locked(stream);
    pw_thread_loop_unlock(audio->loop);
}
