#ifndef SCORE_MUSIC_DEVICES_H
#define SCORE_MUSIC_DEVICES_H

#include <stdint.h>
#include <stddef.h>

typedef struct ScoreMidiEvent {
    uint64_t time_ns;
    uint8_t status;
    uint8_t data1;
    uint8_t data2;
    uint8_t reserved;
} ScoreMidiEvent;

typedef struct ScoreMidiService ScoreMidiService;

ScoreMidiService *score_midi_create(void);
void score_midi_destroy(ScoreMidiService *service);
size_t score_midi_poll(ScoreMidiService *service, ScoreMidiEvent *events, size_t capacity);
void score_midi_send(ScoreMidiService *service, uint8_t status, uint8_t data1, uint8_t data2);
uint32_t score_midi_source_count(const ScoreMidiService *service);
uint32_t score_midi_destination_count(const ScoreMidiService *service);
size_t score_midi_source_name(const ScoreMidiService *service, uint32_t index, char *buffer, size_t capacity);
uint32_t score_midi_selected_source(const ScoreMidiService *service);
int score_midi_select_source(ScoreMidiService *service, uint32_t index);
uint64_t score_host_time_now_ns(void);

typedef void (*ScoreAudioRenderProc)(float *samples, uint32_t frames, uint32_t channels, double sample_rate, void *context);
typedef struct ScoreAudioOutput ScoreAudioOutput;

ScoreAudioOutput *score_audio_output_start(ScoreAudioRenderProc render, void *context);
ScoreAudioOutput *score_audio_output_start_device(ScoreAudioRenderProc render, void *context, uint32_t device_index);
void score_audio_output_stop(ScoreAudioOutput *output);
uint32_t score_audio_output_device_count(void);
uint32_t score_audio_default_output_index(void);
size_t score_audio_output_device_name(uint32_t index, char *buffer, size_t capacity);
double score_audio_output_device_nominal_sample_rate(uint32_t index);
uint32_t score_audio_output_selected_device(const ScoreAudioOutput *output);
double score_audio_output_sample_rate(const ScoreAudioOutput *output);
double score_audio_output_device_sample_rate(const ScoreAudioOutput *output);
double score_audio_output_unit_device_sample_rate(const ScoreAudioOutput *output);
uint32_t score_audio_output_unit_device_channels(const ScoreAudioOutput *output);
uint32_t score_audio_output_device_buffer_frames(const ScoreAudioOutput *output);
uint32_t score_audio_output_device_latency_frames(const ScoreAudioOutput *output);
uint32_t score_audio_output_safety_offset_frames(const ScoreAudioOutput *output);
uint32_t score_audio_output_callback_frames(const ScoreAudioOutput *output);
uint32_t score_audio_output_max_callback_frames(const ScoreAudioOutput *output);
uint32_t score_audio_output_callback_buffers(const ScoreAudioOutput *output);
uint32_t score_audio_output_callback_channels(const ScoreAudioOutput *output);
uint64_t score_audio_output_nonzero_samples(const ScoreAudioOutput *output);
float score_audio_output_callback_peak(const ScoreAudioOutput *output);
uint32_t score_audio_output_device_muted(const ScoreAudioOutput *output);
float score_audio_output_device_volume(const ScoreAudioOutput *output);
uint32_t score_audio_output_device_input_muted(const ScoreAudioOutput *output);
float score_audio_output_device_input_volume(const ScoreAudioOutput *output);
int score_audio_output_set_muted(ScoreAudioOutput *output, int muted);
double score_audio_output_unit_latency_seconds(const ScoreAudioOutput *output);
double score_audio_output_estimated_latency_seconds(const ScoreAudioOutput *output);

typedef void (*ScoreAudioInputProc)(const float *samples, uint32_t frames, double sample_rate, uint64_t time_ns, void *context);
typedef struct ScoreAudioInput ScoreAudioInput;

ScoreAudioInput *score_audio_input_start(ScoreAudioInputProc input, void *context);
ScoreAudioInput *score_audio_input_start_device(ScoreAudioInputProc input, void *context, uint32_t device_index);
void score_audio_input_stop(ScoreAudioInput *input);
int score_audio_input_begin_recording(ScoreAudioInput *input, const char *wav_path);
void score_audio_input_end_recording(ScoreAudioInput *input);
int score_audio_input_is_recording(const ScoreAudioInput *input);
size_t score_audio_default_input_name(char *buffer, size_t capacity);
uint32_t score_audio_input_device_count(void);
uint32_t score_audio_default_input_index(void);
size_t score_audio_input_device_name(uint32_t index, char *buffer, size_t capacity);
uint32_t score_audio_input_selected_device(const ScoreAudioInput *input);
double score_audio_input_sample_rate(const ScoreAudioInput *input);
double score_audio_input_device_sample_rate(const ScoreAudioInput *input);
uint32_t score_audio_input_device_buffer_frames(const ScoreAudioInput *input);
uint32_t score_audio_input_device_latency_frames(const ScoreAudioInput *input);
uint32_t score_audio_input_safety_offset_frames(const ScoreAudioInput *input);
uint32_t score_audio_input_callback_frames(const ScoreAudioInput *input);
uint32_t score_audio_input_max_callback_frames(const ScoreAudioInput *input);
double score_audio_input_estimated_latency_seconds(const ScoreAudioInput *input);

#endif
