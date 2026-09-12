/* A private device whose hardware route volumes differ from its node volumes. */
#include <assert.h>
#include <signal.h>
#include <stdio.h>
#include <spa/monitor/device.h>
#include <spa/param/audio/raw.h>
#include <spa/param/props.h>
#include <spa/param/route.h>
#include <spa/param/profile.h>
#include <spa/pod/builder.h>
#include <spa/pod/parser.h>
#include <spa/pod/iter.h>
#include <pipewire/pipewire.h>

struct fixture {
    struct spa_device device;
    struct spa_hook_list listeners;
    struct spa_param_info params[4];
    struct pw_main_loop *loop;
    struct pw_core *core;
    struct spa_source *timer;
    float volumes[2][2];
    bool muted[2];
    int pending;
    bool routes_hidden;
    bool catalog_changed;
    int active_ports[2];
    int pending_port;
    bool suppress_report;
    const char *control;
    unsigned port_requests;
    bool profile_mode;
    uint32_t device_id;
    uint32_t active_profile;
    int pending_profile;
    unsigned profile_requests;
    float pending_volumes[2];
    bool pending_mute;
    struct pw_proxy *nodes[2];
};

static void info(struct fixture *f) {
    struct spa_device_info value = SPA_DEVICE_INFO_INIT();
    value.change_mask = SPA_DEVICE_CHANGE_MASK_PARAMS;
    value.params = f->params;
    value.n_params = 4;
    spa_hook_list_call(&f->listeners, struct spa_device_events, info, 0, &value);
}

static int add_listener(void *object, struct spa_hook *listener,
                        const struct spa_device_events *events, void *data) {
    struct fixture *f = object;
    struct spa_hook_list previous;
    spa_hook_list_isolate(&f->listeners, &previous, listener, events, data);
    info(f);
    spa_hook_list_join(&f->listeners, &previous);
    return 0;
}

static int enum_catalog(struct fixture *f, int seq, uint32_t id, uint32_t start, uint32_t count) {
    if (id != SPA_PARAM_EnumProfile && id != SPA_PARAM_Profile && id != SPA_PARAM_EnumRoute) return -ENOENT;
    uint32_t total = id == SPA_PARAM_Profile ? 1 : 4;
    for (uint32_t i = start; i < total && count--; i++) {
        uint8_t buffer[2048];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
        struct spa_pod_frame object;
        if (id == SPA_PARAM_EnumRoute) {
            const char *names[] = {"[Out] Speaker", "[Out] Headphones", "[In] Mic", "[In] Line"};
            int32_t profiles[] = {1, 3}, devices[] = {i < 2 ? 4 : 0};
            spa_pod_builder_push_object(&b, &object, SPA_TYPE_OBJECT_ParamRoute, id);
            spa_pod_builder_add(&b,
                SPA_PARAM_ROUTE_index, SPA_POD_Int(i < 2 ? 2+i : 5+i),
                SPA_PARAM_ROUTE_name, SPA_POD_String(names[i]),
                SPA_PARAM_ROUTE_description, SPA_POD_String(names[i]),
                SPA_PARAM_ROUTE_priority, SPA_POD_Int(100-(int)i),
                SPA_PARAM_ROUTE_direction, SPA_POD_Id(i < 2 ? SPA_DIRECTION_OUTPUT : SPA_DIRECTION_INPUT),
                SPA_PARAM_ROUTE_available, SPA_POD_Id(f->catalog_changed && i % 2 ? SPA_PARAM_AVAILABILITY_no : SPA_PARAM_AVAILABILITY_yes),
                SPA_PARAM_ROUTE_profiles, SPA_POD_Array(sizeof(int32_t), SPA_TYPE_Int, 2, profiles),
                SPA_PARAM_ROUTE_devices, SPA_POD_Array(sizeof(int32_t), SPA_TYPE_Int, 1, devices), 0);
        } else {
            const char *names[] = {"off", "HiFi", "pro-audio", "headset"};
            uint32_t index = id == SPA_PARAM_Profile ? (f->profile_mode ? f->active_profile : (f->catalog_changed ? 3 : 1)) : i;
            spa_pod_builder_push_object(&b, &object, SPA_TYPE_OBJECT_ParamProfile, id);
            spa_pod_builder_add(&b,
                SPA_PARAM_PROFILE_index, SPA_POD_Int(index),
                SPA_PARAM_PROFILE_name, SPA_POD_String(names[index]),
                SPA_PARAM_PROFILE_description, SPA_POD_String(names[index]),
                SPA_PARAM_PROFILE_priority, SPA_POD_Int(index ? 100 : 0),
                SPA_PARAM_PROFILE_available, SPA_POD_Id((!f->profile_mode && index == 3) || (f->catalog_changed && index == 1) ? SPA_PARAM_AVAILABILITY_no : SPA_PARAM_AVAILABILITY_yes), 0);
            if (index) {
                struct spa_pod_frame classes, class;
                spa_pod_builder_prop(&b, SPA_PARAM_PROFILE_classes, 0);
                spa_pod_builder_push_struct(&b, &classes);
                spa_pod_builder_int(&b, 2);
                for (int c = 0; c < 2; c++) {
                    int32_t device = c ? 0 : 4;
                    spa_pod_builder_push_struct(&b, &class);
                    spa_pod_builder_add(&b, SPA_POD_String(c ? "Audio/Source" : "Audio/Sink"),
                        SPA_POD_Int(1), SPA_POD_String("card.profile.devices"),
                        SPA_POD_Array(sizeof(int32_t), SPA_TYPE_Int, 1, &device), 0);
                    spa_pod_builder_pop(&b, &class);
                }
                spa_pod_builder_pop(&b, &classes);
            }
        }
        struct spa_result_device_params result = { .id = id, .index = i, .next = i+1,
            .param = spa_pod_builder_pop(&b, &object) };
        spa_hook_list_call(&f->listeners, struct spa_device_events, result, 0,
                          seq, 0, SPA_RESULT_TYPE_DEVICE_PARAMS, &result);
    }
    return 0;
}

static int enum_params(void *object, int seq, uint32_t id, uint32_t start,
                       uint32_t count, const struct spa_pod *filter) {
    struct fixture *f = object;
    if (id != SPA_PARAM_Route) return enum_catalog(f, seq, id, start, count);
    if (f->routes_hidden || (f->profile_mode && f->active_profile == 0)) return 0;
    for (uint32_t i = start; i < 2 && count--; i++) {
        uint8_t buffer[1024];
        struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
        uint32_t map[] = { SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR };
        struct spa_pod_frame route, props;
        spa_pod_builder_push_object(&b, &route, SPA_TYPE_OBJECT_ParamRoute, SPA_PARAM_Route);
        spa_pod_builder_add(&b,
            SPA_PARAM_ROUTE_index, SPA_POD_Int(f->active_ports[i]),
            SPA_PARAM_ROUTE_device, SPA_POD_Int(i ? 0 : 4),
            SPA_PARAM_ROUTE_direction, SPA_POD_Id(i ? SPA_DIRECTION_INPUT : SPA_DIRECTION_OUTPUT), 0);
        spa_pod_builder_prop(&b, SPA_PARAM_ROUTE_props, 0);
        spa_pod_builder_push_object(&b, &props, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props);
        spa_pod_builder_add(&b,
            SPA_PROP_channelVolumes, SPA_POD_Array(sizeof(float), SPA_TYPE_Float, 2, f->volumes[i]),
            SPA_PROP_channelMap, SPA_POD_Array(sizeof(uint32_t), SPA_TYPE_Id, 2, map),
            SPA_PROP_mute, SPA_POD_Bool(f->muted[i]), 0);
        spa_pod_builder_pop(&b, &props);
        struct spa_result_device_params result = {
            .id = id, .index = i, .next = i + 1,
            .param = spa_pod_builder_pop(&b, &route),
        };
        spa_hook_list_call(&f->listeners, struct spa_device_events, result, 0,
                          seq, 0, SPA_RESULT_TYPE_DEVICE_PARAMS, &result);
    }
    return 0;
}

static void bound(void *data, uint32_t id);

static void apply(void *data, uint64_t expirations) {
    struct fixture *f = data;
    int i = f->pending;
    if (f->pending_profile >= 0) {
        for (int n = 0; n < 2; n++) {
            if (f->nodes[n]) pw_proxy_destroy(f->nodes[n]);
            f->nodes[n] = NULL;
            f->volumes[n][0] = f->volumes[n][1] = 1.f;
            f->muted[n] = false;
        }
        f->active_profile = f->pending_profile;
        f->pending_profile = -1;
        if (f->active_profile) bound(f, f->device_id);
        if (f->suppress_report) { f->suppress_report = false; return; }
        f->params[2].flags ^= SPA_PARAM_INFO_SERIAL;
        f->params[0].flags ^= SPA_PARAM_INFO_SERIAL;
        info(f);
        return;
    }
    if (i < 0) return;
    memcpy(f->volumes[i], f->pending_volumes, sizeof(f->pending_volumes));
    f->muted[i] = f->pending_mute;
    f->active_ports[i] = f->pending_port;
    f->pending = -1;
    if (f->suppress_report) { f->suppress_report = false; return; }
    f->params[0].flags ^= SPA_PARAM_INFO_SERIAL;
    info(f);
}

static int set_param(void *object, uint32_t id, uint32_t flags, const struct spa_pod *param) {
    struct fixture *f = object;
    int32_t index = -1, device = -1;
    bool save = false;
    struct spa_pod *props = NULL, *volumes = NULL;
    if (id == SPA_PARAM_Profile && f->profile_mode) {
        if (spa_pod_parse_object(param, SPA_TYPE_OBJECT_ParamProfile, NULL,
            SPA_PARAM_PROFILE_index, SPA_POD_Int(&index),
            SPA_PARAM_PROFILE_save, SPA_POD_Bool(&save)) < 0 || !save || index < 0 || index > 3
            || f->pending >= 0 || f->pending_profile >= 0) return -EINVAL;
        char mode[32] = "";
        FILE *control = f->control ? fopen(f->control, "r") : NULL;
        if (control) { assert(fgets(mode, sizeof(mode), control)); fclose(control); }
        printf("PROFILE %d\n", index);
        fflush(stdout);
        if (strcmp(mode, "profile-ignore") == 0) return 0;
        if (strcmp(mode, "profile-silent-once") == 0 && f->profile_requests++ == 0) f->suppress_report = true;
        f->pending_profile = strcmp(mode, "profile-third") == 0 ? 0 : index;
        struct timespec delay = { .tv_nsec = 80000000 };
        pw_loop_update_timer(pw_main_loop_get_loop(f->loop), f->timer, &delay, NULL, false);
        return 0;
    }
    if (id != SPA_PARAM_Route || spa_pod_parse_object(param,
        SPA_TYPE_OBJECT_ParamRoute, NULL,
        SPA_PARAM_ROUTE_index, SPA_POD_Int(&index),
        SPA_PARAM_ROUTE_device, SPA_POD_Int(&device),
        SPA_PARAM_ROUTE_props, SPA_POD_OPT_Pod(&props),
        SPA_PARAM_ROUTE_save, SPA_POD_Bool(&save)) < 0) return -EINVAL;
    int i = (index == 2 || index == 3) && device == 4 ? 0 : (index == 7 || index == 8) && device == 0 ? 1 : -1;
    if (i < 0 || !save || f->pending >= 0) return -EINVAL;
    if (!props) {
        char mode[32] = "";
        FILE *control = f->control ? fopen(f->control, "r") : NULL;
        if (control) { assert(fgets(mode, sizeof(mode), control)); fclose(control); }
        printf("PORT %d %d\n", device, index);
        fflush(stdout);
        if (strcmp(mode, "ignore") == 0) return 0;
        if (strcmp(mode, "silent") == 0) f->suppress_report = true;
        if (strcmp(mode, "silent-once") == 0 && f->port_requests++ == 0) f->suppress_report = true;
    }
    f->pending_port = index;
    f->pending_mute = f->muted[i];
    memcpy(f->pending_volumes, f->volumes[i], sizeof(f->pending_volumes));
    if (props && spa_pod_parse_object(props, SPA_TYPE_OBJECT_Props, NULL,
        SPA_PROP_channelVolumes, SPA_POD_OPT_Pod(&volumes),
        SPA_PROP_mute, SPA_POD_OPT_Bool(&f->pending_mute)) < 0) return -EINVAL;
    if (volumes && spa_pod_copy_array(volumes, SPA_TYPE_Float,
                                     f->pending_volumes, 2) != 2) return -EINVAL;
    f->pending = i;
    struct timespec delay = { .tv_nsec = 80000000 };
    pw_loop_update_timer(pw_main_loop_get_loop(f->loop), f->timer, &delay, NULL, false);
    return 0;
}

static int sync_device(void *object, int seq) {
    struct fixture *f = object;
    spa_hook_list_call(&f->listeners, struct spa_device_events, result, 0, seq, 0, 0, NULL);
    return 0;
}

static const struct spa_device_methods methods = {
    SPA_VERSION_DEVICE_METHODS,
    .add_listener = add_listener, .sync = sync_device, .enum_params = enum_params, .set_param = set_param,
};

static void bound(void *data, uint32_t id) {
    struct fixture *f = data;
    f->device_id = id;
    char device_id[24];
    snprintf(device_id, sizeof(device_id), "%u", id);
    for (int i = 0; i < 2; i++) {
        struct pw_properties *props = pw_properties_new(
            "factory.name", "support.null-audio-sink",
            "node.name", i ? "audio_test_routed_input" : "audio_test_routed_output",
            "media.class", i ? "Audio/Source" : "Audio/Sink",
            "audio.position", "[ FL FR ]", "device.id", device_id,
            "adapter.auto-port-config", "{ mode = dsp monitor = true position = preserve }",
            "card.profile.device", i ? "0" : "4", NULL);
        f->nodes[i] = pw_core_create_object(f->core, "adapter", PW_TYPE_INTERFACE_Node,
                                          PW_VERSION_NODE, &props->dict, 0);
        pw_properties_free(props);
        assert(f->nodes[i]);
    }
}

static void toggle_routes(void *data, int signal) {
    struct fixture *f = data;
    f->routes_hidden = !f->routes_hidden;
    f->params[0].flags ^= SPA_PARAM_INFO_SERIAL;
    info(f);
}

static void toggle_catalog(void *data, int signal) {
    struct fixture *f = data;
    f->catalog_changed = !f->catalog_changed;
    f->active_ports[0] = f->catalog_changed ? 3 : 2;
    for (unsigned i = 0; i < 4; i++) f->params[i].flags ^= SPA_PARAM_INFO_SERIAL;
    info(f);
}

static void quit(void *data, int signal) {
    pw_main_loop_quit(((struct fixture *)data)->loop);
}

int main(int argc, char **argv) {
    pw_init(&argc, &argv);
    struct fixture f = { .pending = -1, .pending_profile = -1, .active_profile = 1, .profile_mode = argc > 2, .active_ports = {2, 7},
        .volumes = {{.008f, .027f}, {.064f, .125f}}, .control = argc > 1 ? argv[1] : NULL };
    uint32_t ids[] = {SPA_PARAM_Route, SPA_PARAM_EnumProfile, SPA_PARAM_Profile, SPA_PARAM_EnumRoute};
    for (unsigned i = 0; i < 4; i++) f.params[i] = (struct spa_param_info) {
        .id = ids[i], .flags = (i == 0 || (i == 2 && f.profile_mode)) ? SPA_PARAM_INFO_READWRITE : SPA_PARAM_INFO_READ };
    f.device.iface = SPA_INTERFACE_INIT(SPA_TYPE_INTERFACE_Device, SPA_VERSION_DEVICE, &methods, &f);
    spa_hook_list_init(&f.listeners);
    f.loop = pw_main_loop_new(NULL);
    struct pw_loop *loop = pw_main_loop_get_loop(f.loop);
    f.timer = pw_loop_add_timer(loop, apply, &f);
    pw_loop_add_signal(loop, SIGUSR1, toggle_routes, &f);
    pw_loop_add_signal(loop, SIGUSR2, toggle_catalog, &f);
    pw_loop_add_signal(loop, SIGINT, quit, &f);
    pw_loop_add_signal(loop, SIGTERM, quit, &f);
    struct pw_context *context = pw_context_new(loop, NULL, 0);
    f.core = pw_context_connect(context, NULL, 0);
    assert(f.core);
    struct pw_properties *props = pw_properties_new("device.name", "audio_test_device", NULL);
    if (argc > 3) pw_properties_set(props, "device.api", "bluez5");
    if (argc > 3) pw_properties_set(props, "api.bluez5.address", "AA:BB:CC:DD:EE:FF");
    struct pw_proxy *proxy = pw_core_export(f.core, SPA_TYPE_INTERFACE_Device, &props->dict, &f.device, 0);
    assert(proxy);
    struct spa_hook listener;
    const struct pw_proxy_events events = { PW_VERSION_PROXY_EVENTS, .bound = bound };
    pw_proxy_add_listener(proxy, &listener, &events, &f);
    pw_main_loop_run(f.loop);
    pw_context_destroy(context);
    pw_main_loop_destroy(f.loop);
    pw_properties_free(props);
    return 0;
}
