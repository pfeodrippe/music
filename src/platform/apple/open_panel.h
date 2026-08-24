#ifndef SCORE_OPEN_PANEL_H
#define SCORE_OPEN_PANEL_H

const char *score_open_score_panel(void);
const char *score_open_instrument_panel(void);
const char *score_save_score_panel(void);
const char *score_save_take_panel(void);
const char *score_application_support_path(void);
int score_current_work_area(int *x, int *y, int *width, int *height);
void score_replay_audio_file(const char *path);
void *score_pdf_begin(const char *path, double width_points, double height_points);
int score_pdf_append_bgra(void *context, const unsigned char *pixels, unsigned int width, unsigned int height, unsigned int stride);
void score_pdf_end(void *context);

typedef struct ScoreAccessibilityItemNative {
    unsigned int id;
    unsigned int role;
    float rect[4];
    unsigned int label_len;
    unsigned int flags;
    unsigned char label[48];
} ScoreAccessibilityItemNative;

typedef void (*ScoreAccessibilityActivateCallback)(unsigned int id, void *context);
void score_accessibility_update(const ScoreAccessibilityItemNative *items, unsigned int count, ScoreAccessibilityActivateCallback callback, void *context);

#endif
