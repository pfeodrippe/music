#ifndef SCORE_IOS_H
#define SCORE_IOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ScoreDrawItem {
    float rect[4];
    float color[4];
    float params[4];
} ScoreDrawItem;

typedef struct ScorePlaybackEvent {
    uint8_t pitch;
    uint8_t velocity;
    uint8_t channel;
    uint8_t on;
} ScorePlaybackEvent;

typedef struct ScoreAccessibilityItem {
    uint32_t id;
    uint32_t role;
    float rect[4];
    uint32_t label_len;
    uint32_t flags;
    uint8_t label[48];
} ScoreAccessibilityItem;

uint32_t score_ios_api_version(void);
bool score_ios_create(float width, float height, float pixel_ratio);
void score_ios_destroy(void);
void score_ios_frame(float delta_seconds);
void score_ios_resize(float width, float height, float pixel_ratio);
void score_ios_pointer(uint32_t kind, uint32_t pointer_type, uint32_t pointer_id, float x, float y, uint32_t buttons, float pressure, float tilt_x, float tilt_y);
void score_ios_key(uint32_t key, uint32_t modifiers, uint32_t pressed, uint32_t repeat);
void score_ios_midi(uint64_t time_ns, uint8_t status, uint8_t data1, uint8_t data2);
void score_ios_microphone_pitch(uint8_t pitch, float confidence);
uint32_t score_ios_detect_pitch(const float *samples, size_t frame_count, float sample_rate, float *confidence);
const ScoreDrawItem *score_ios_draw_items(void);
uint32_t score_ios_draw_count(void);
const ScoreAccessibilityItem *score_ios_accessibility_items(void);
uint32_t score_ios_accessibility_count(void);
void score_ios_accessibility_activate(uint32_t id);
uint32_t score_ios_host_request(void);
void score_ios_set_host_status(uint32_t status);
size_t score_ios_drain_playback(ScorePlaybackEvent *events, size_t capacity);
uint32_t score_ios_import(const uint8_t *bytes, size_t length, uint32_t kind);
size_t score_ios_serialize(uint8_t *bytes, size_t capacity);
uint32_t score_ios_restore(const uint8_t *bytes, size_t length);

#endif
