#include "music_devices.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SCORE_MIDI_QUEUE_CAPACITY 4096u

struct ScoreMidiService {
    MIDIClientRef client;
    MIDIPortRef input_port;
    MIDIPortRef output_port;
    _Atomic uint32_t write_index;
    _Atomic uint32_t read_index;
    uint8_t running_status;
    ScoreMidiEvent events[SCORE_MIDI_QUEUE_CAPACITY];
};

static uint64_t score_host_time_to_ns(uint64_t host_time) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    if (host_time == 0) host_time = mach_absolute_time();
    return host_time * timebase.numer / timebase.denom;
}

static void score_midi_push(ScoreMidiService *service, MIDITimeStamp timestamp, uint8_t status, uint8_t data1, uint8_t data2) {
    uint32_t write = atomic_load_explicit(&service->write_index, memory_order_relaxed);
    uint32_t next = (write + 1u) % SCORE_MIDI_QUEUE_CAPACITY;
    if (next == atomic_load_explicit(&service->read_index, memory_order_acquire)) return;
    service->events[write] = (ScoreMidiEvent){score_host_time_to_ns(timestamp), status, data1, data2, 0};
    atomic_store_explicit(&service->write_index, next, memory_order_release);
}

static size_t score_midi_message_length(uint8_t status) {
    uint8_t message = status & 0xf0u;
    if (message == 0xc0u || message == 0xd0u) return 2;
    if (message >= 0x80u && message <= 0xe0u) return 3;
    return 0;
}

static void score_midi_read(const MIDIPacketList *packet_list, void *context, void *source_context) {
    (void)source_context;
    ScoreMidiService *service = (ScoreMidiService *)context;
    const MIDIPacket *packet = &packet_list->packet[0];
    for (UInt32 packet_index = 0; packet_index < packet_list->numPackets; ++packet_index) {
        size_t offset = 0;
        while (offset < packet->length) {
            uint8_t status = packet->data[offset];
            if (status >= 0xf8u) {
                offset += 1;
                continue;
            }
            if ((status & 0x80u) != 0) {
                service->running_status = status;
                offset += 1;
            } else {
                status = service->running_status;
            }
            size_t message_length = score_midi_message_length(status);
            if (message_length == 0 || offset + message_length - 1 > packet->length) break;
            uint8_t data1 = packet->data[offset];
            uint8_t data2 = message_length == 3 ? packet->data[offset + 1] : 0;
            score_midi_push(service, packet->timeStamp, status, data1, data2);
            offset += message_length - 1;
        }
        packet = MIDIPacketNext(packet);
    }
}

ScoreMidiService *score_midi_create(void) {
    ScoreMidiService *service = (ScoreMidiService *)calloc(1, sizeof(ScoreMidiService));
    if (service == NULL) return NULL;
    if (MIDIClientCreate(CFSTR("Score"), NULL, NULL, &service->client) != noErr) goto fail;
    if (MIDIInputPortCreate(service->client, CFSTR("Score Input"), score_midi_read, service, &service->input_port) != noErr) goto fail;
    if (MIDIOutputPortCreate(service->client, CFSTR("Score Output"), &service->output_port) != noErr) goto fail;
    ItemCount sources = MIDIGetNumberOfSources();
    for (ItemCount index = 0; index < sources; ++index) {
        MIDIEndpointRef source = MIDIGetSource(index);
        if (source != 0) MIDIPortConnectSource(service->input_port, source, NULL);
    }
    return service;
fail:
    score_midi_destroy(service);
    return NULL;
}

void score_midi_destroy(ScoreMidiService *service) {
    if (service == NULL) return;
    if (service->input_port != 0) MIDIPortDispose(service->input_port);
    if (service->output_port != 0) MIDIPortDispose(service->output_port);
    if (service->client != 0) MIDIClientDispose(service->client);
    free(service);
}

size_t score_midi_poll(ScoreMidiService *service, ScoreMidiEvent *events, size_t capacity) {
    if (service == NULL || events == NULL) return 0;
    size_t count = 0;
    uint32_t read = atomic_load_explicit(&service->read_index, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&service->write_index, memory_order_acquire);
    while (read != write && count < capacity) {
        events[count++] = service->events[read];
        read = (read + 1u) % SCORE_MIDI_QUEUE_CAPACITY;
    }
    atomic_store_explicit(&service->read_index, read, memory_order_release);
    return count;
}

void score_midi_send(ScoreMidiService *service, uint8_t status, uint8_t data1, uint8_t data2) {
    if (service == NULL || service->output_port == 0) return;
    Byte storage[64];
    MIDIPacketList *packets = (MIDIPacketList *)storage;
    MIDIPacket *packet = MIDIPacketListInit(packets);
    Byte data[3] = {status, data1, data2};
    packet = MIDIPacketListAdd(packets, sizeof(storage), packet, 0, 3, data);
    if (packet == NULL) return;
    ItemCount destinations = MIDIGetNumberOfDestinations();
    for (ItemCount index = 0; index < destinations; ++index) {
        MIDIEndpointRef destination = MIDIGetDestination(index);
        if (destination != 0) MIDISend(service->output_port, destination, packets);
    }
}

uint32_t score_midi_source_count(const ScoreMidiService *service) {
    return service == NULL ? 0 : (uint32_t)MIDIGetNumberOfSources();
}

uint32_t score_midi_destination_count(const ScoreMidiService *service) {
    return service == NULL ? 0 : (uint32_t)MIDIGetNumberOfDestinations();
}

struct ScoreAudioOutput {
    AudioComponentInstance unit;
    ScoreAudioRenderProc render;
    void *context;
    double sample_rate;
    float *scratch;
    uint32_t scratch_frames;
};

static OSStatus score_audio_render_callback(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    (void)flags;
    (void)timestamp;
    (void)bus;
    ScoreAudioOutput *output = (ScoreAudioOutput *)context;
    if (output == NULL || output->render == NULL || buffers == NULL) return noErr;
    if (frames > output->scratch_frames) frames = output->scratch_frames;
    output->render(output->scratch, frames, 2, output->sample_rate, output->context);
    if (buffers->mNumberBuffers == 1 && buffers->mBuffers[0].mDataByteSize >= frames * 2 * sizeof(float)) {
        memcpy(buffers->mBuffers[0].mData, output->scratch, frames * 2 * sizeof(float));
    } else {
        for (UInt32 channel = 0; channel < buffers->mNumberBuffers && channel < 2; ++channel) {
            float *destination = (float *)buffers->mBuffers[channel].mData;
            for (UInt32 frame = 0; frame < frames; ++frame) destination[frame] = output->scratch[frame * 2 + channel];
        }
    }
    return noErr;
}

ScoreAudioOutput *score_audio_output_start(ScoreAudioRenderProc render, void *context) {
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (component == NULL) return NULL;
    ScoreAudioOutput *output = (ScoreAudioOutput *)calloc(1, sizeof(ScoreAudioOutput));
    if (output == NULL) return NULL;
    output->render = render;
    output->context = context;
    output->sample_rate = 48000.0;
    output->scratch_frames = 8192;
    output->scratch = (float *)calloc(output->scratch_frames * 2, sizeof(float));
    if (output->scratch == NULL) goto fail;
    if (AudioComponentInstanceNew(component, &output->unit) != noErr) goto fail;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = output->sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 2 * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * sizeof(float);
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    if (AudioUnitSetProperty(output->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr) goto fail;
    AURenderCallbackStruct callback = {score_audio_render_callback, output};
    if (AudioUnitSetProperty(output->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr) goto fail;
    if (AudioUnitInitialize(output->unit) != noErr) goto fail;
    if (AudioOutputUnitStart(output->unit) != noErr) goto fail;
    return output;
fail:
    score_audio_output_stop(output);
    return NULL;
}

void score_audio_output_stop(ScoreAudioOutput *output) {
    if (output == NULL) return;
    if (output->unit != NULL) {
        AudioOutputUnitStop(output->unit);
        AudioUnitUninitialize(output->unit);
        AudioComponentInstanceDispose(output->unit);
    }
    free(output->scratch);
    free(output);
}

double score_audio_output_sample_rate(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0 : output->sample_rate;
}

struct ScoreAudioInput {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[3];
    AudioStreamBasicDescription format;
    ScoreAudioInputProc input;
    void *context;
    AudioFileID recording;
    SInt64 packet_position;
};

static void score_audio_input_callback(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *start_time, UInt32 packet_count, const AudioStreamPacketDescription *descriptions) {
    (void)descriptions;
    ScoreAudioInput *input = (ScoreAudioInput *)context;
    if (input == NULL || buffer == NULL) return;
    UInt32 frames = buffer->mAudioDataByteSize / sizeof(float);
    if (input->input != NULL && frames != 0) {
        uint64_t timestamp = start_time != NULL && (start_time->mFlags & kAudioTimeStampHostTimeValid) ? start_time->mHostTime : 0;
        input->input((const float *)buffer->mAudioData, frames, input->format.mSampleRate, score_host_time_to_ns(timestamp), input->context);
    }
    if (input->recording != 0 && buffer->mAudioDataByteSize != 0) {
        UInt32 packets = packet_count == 0 ? frames : packet_count;
        AudioFileWritePackets(input->recording, false, buffer->mAudioDataByteSize, NULL, input->packet_position, &packets, buffer->mAudioData);
        input->packet_position += packets;
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

ScoreAudioInput *score_audio_input_start(ScoreAudioInputProc input_proc, void *context) {
    ScoreAudioInput *input = (ScoreAudioInput *)calloc(1, sizeof(ScoreAudioInput));
    if (input == NULL) return NULL;
    input->input = input_proc;
    input->context = context;
    input->format.mSampleRate = 48000.0;
    input->format.mFormatID = kAudioFormatLinearPCM;
    input->format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    input->format.mBytesPerPacket = sizeof(float);
    input->format.mFramesPerPacket = 1;
    input->format.mBytesPerFrame = sizeof(float);
    input->format.mChannelsPerFrame = 1;
    input->format.mBitsPerChannel = 32;
    if (AudioQueueNewInput(&input->format, score_audio_input_callback, input, NULL, NULL, 0, &input->queue) != noErr) goto fail;
    const UInt32 buffer_bytes = 4096 * sizeof(float);
    for (size_t index = 0; index < 3; ++index) {
        if (AudioQueueAllocateBuffer(input->queue, buffer_bytes, &input->buffers[index]) != noErr) goto fail;
        if (AudioQueueEnqueueBuffer(input->queue, input->buffers[index], 0, NULL) != noErr) goto fail;
    }
    if (AudioQueueStart(input->queue, NULL) != noErr) goto fail;
    return input;
fail:
    score_audio_input_stop(input);
    return NULL;
}

void score_audio_input_stop(ScoreAudioInput *input) {
    if (input == NULL) return;
    score_audio_input_end_recording(input);
    if (input->queue != NULL) {
        AudioQueueStop(input->queue, true);
        AudioQueueDispose(input->queue, true);
    }
    free(input);
}

int score_audio_input_begin_recording(ScoreAudioInput *input, const char *wav_path) {
    if (input == NULL || wav_path == NULL) return 0;
    score_audio_input_end_recording(input);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)wav_path, (CFIndex)strlen(wav_path), false);
    if (url == NULL) return 0;
    OSStatus status = AudioFileCreateWithURL(url, kAudioFileWAVEType, &input->format, kAudioFileFlags_EraseFile, &input->recording);
    CFRelease(url);
    input->packet_position = 0;
    return status == noErr;
}

void score_audio_input_end_recording(ScoreAudioInput *input) {
    if (input == NULL || input->recording == 0) return;
    AudioFileClose(input->recording);
    input->recording = 0;
}

int score_audio_input_is_recording(const ScoreAudioInput *input) {
    return input != NULL && input->recording != 0;
}
