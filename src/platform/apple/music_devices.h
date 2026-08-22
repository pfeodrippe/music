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

typedef void (*ScoreAudioRenderProc)(float *samples, uint32_t frames, uint32_t channels, double sample_rate, void *context);
typedef struct ScoreAudioOutput ScoreAudioOutput;

ScoreAudioOutput *score_audio_output_start(ScoreAudioRenderProc render, void *context);
void score_audio_output_stop(ScoreAudioOutput *output);
double score_audio_output_sample_rate(const ScoreAudioOutput *output);

typedef void (*ScoreAudioInputProc)(const float *samples, uint32_t frames, double sample_rate, uint64_t time_ns, void *context);
typedef struct ScoreAudioInput ScoreAudioInput;

ScoreAudioInput *score_audio_input_start(ScoreAudioInputProc input, void *context);
void score_audio_input_stop(ScoreAudioInput *input);
int score_audio_input_begin_recording(ScoreAudioInput *input, const char *wav_path);
void score_audio_input_end_recording(ScoreAudioInput *input);
int score_audio_input_is_recording(const ScoreAudioInput *input);

#endif
