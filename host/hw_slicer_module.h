#ifndef HW_SLICER_MODULE_H
#define HW_SLICER_MODULE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define HW_SLICER_MODULE_API_VERSION 1u

typedef struct HW_Slicer_Rect {
    double x;
    double y;
    double width;
    double height;
} HW_Slicer_Rect;

typedef struct HW_Slicer_Control {
    uint64_t id;
    const char *name;
    const char *label;
    HW_Slicer_Rect rect;
    int32_t role;
    bool enabled;
} HW_Slicer_Control;

typedef struct HW_Slicer_Host {
    void *application;
    void *window;
    void *view;
    void *layer;
    const char *resource_root;
    void (*request_redraw)(void);
    void (*window_close)(void);
    void (*window_minimize)(void);
    void (*window_zoom)(void);
    bool (*open_stl_file)(char *path, size_t capacity);
    int32_t (*preference_get_int)(const char *key, int32_t fallback);
    void (*preference_set_int)(const char *key, int32_t value);
} HW_Slicer_Host;

typedef struct HW_Slicer_Module_API {
    uint32_t api_version;
    uint32_t state_version;
    size_t snapshot_size;
    bool (*initialize)(
        const HW_Slicer_Host *host,
        const void *snapshot,
        size_t snapshot_size
    );
    bool (*can_reload)(void);
    void (*capture)(void *snapshot, size_t snapshot_size);
    void (*shutdown)(void);
    void (*frame)(double width, double height, double scale);
    void (*mouse)(
        int32_t phase,
        int32_t button,
        double x,
        double y,
        double delta_x,
        double delta_y
    );
    void (*scroll)(double delta_x, double delta_y);
    void (*key)(
        uint16_t key_code,
        const char *characters,
        uint64_t modifiers
    );
    size_t (*control_count)(void);
    bool (*control_at)(size_t index, HW_Slicer_Control *control);
    uint64_t (*hit_test)(double x, double y);
    bool (*activate_control)(uint64_t control_id);
    bool (*write_ui_snapshot)(const char *path);
} HW_Slicer_Module_API;

typedef const HW_Slicer_Module_API *(*HW_Slicer_Module_Entry)(void);

#endif
