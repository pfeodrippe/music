#include "music_devices.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreMIDI/CoreMIDI.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SCORE_MIDI_QUEUE_CAPACITY 4096u
#define SCORE_MIDI_RUNNING_STATUS_SLOTS 64u
#define SCORE_MIDI_ALL_SOURCES UINT32_MAX
#define SCORE_AUDIO_DEFAULT_DEVICE UINT32_MAX

struct ScoreMidiService {
    MIDIClientRef client;
    MIDIPortRef input_port;
    MIDIPortRef output_port;
    MIDIEndpointRef virtual_source;
    _Atomic uint32_t write_index;
    _Atomic uint32_t read_index;
    uint8_t running_status[SCORE_MIDI_RUNNING_STATUS_SLOTS];
    uint32_t selected_source;
    ScoreMidiEvent events[SCORE_MIDI_QUEUE_CAPACITY];
};

static uint64_t score_host_time_to_ns(uint64_t host_time) {
    static mach_timebase_info_data_t timebase = {0, 0};
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    if (host_time == 0) host_time = mach_absolute_time();
    return host_time * timebase.numer / timebase.denom;
}

uint64_t score_host_time_now_ns(void) {
    return score_host_time_to_ns(mach_absolute_time());
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
    ScoreMidiService *service = (ScoreMidiService *)context;
    uintptr_t source_token = (uintptr_t)source_context;
    size_t source_index = source_token == 0 ? 0 : source_token - 1;
    if (source_index >= SCORE_MIDI_RUNNING_STATUS_SLOTS) source_index = SCORE_MIDI_RUNNING_STATUS_SLOTS - 1;
    uint8_t *running_status = &service->running_status[source_index];
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
                *running_status = status;
                offset += 1;
            } else {
                status = *running_status;
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

static ItemCount score_midi_external_source_count(const ScoreMidiService *service) {
    ItemCount count = 0;
    ItemCount sources = MIDIGetNumberOfSources();
    for (ItemCount index = 0; index < sources; ++index) {
        MIDIEndpointRef source = MIDIGetSource(index);
        if (source != 0 && (service == NULL || source != service->virtual_source)) count += 1;
    }
    return count;
}

static MIDIEndpointRef score_midi_external_source_at(const ScoreMidiService *service, ItemCount requested) {
    ItemCount logical_index = 0;
    ItemCount sources = MIDIGetNumberOfSources();
    for (ItemCount index = 0; index < sources; ++index) {
        MIDIEndpointRef source = MIDIGetSource(index);
        if (source == 0 || (service != NULL && source == service->virtual_source)) continue;
        if (logical_index == requested) return source;
        logical_index += 1;
    }
    return 0;
}

static bool score_midi_source_name_exists(const char *candidate) {
    if (candidate == NULL || candidate[0] == '\0') return false;
    const ItemCount sources = MIDIGetNumberOfSources();
    for (ItemCount index = 0; index < sources; ++index) {
        const MIDIEndpointRef source = MIDIGetSource(index);
        CFStringRef name = NULL;
        if (source == 0 || MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) != noErr || name == NULL) continue;
        char existing[256] = {0};
        const bool equal = CFStringGetCString(name, existing, sizeof(existing), kCFStringEncodingUTF8) && strcmp(existing, candidate) == 0;
        CFRelease(name);
        if (equal) return true;
    }
    return false;
}

static CFStringRef score_midi_unique_endpoint_name(const char *requested_name) {
    const char *base = requested_name == NULL || requested_name[0] == '\0' ? "Score Controller — Mac" : requested_name;
    char candidate[256] = {0};
    for (unsigned int instance = 1; instance < 1000; ++instance) {
        if (instance == 1) snprintf(candidate, sizeof(candidate), "%s", base);
        else snprintf(candidate, sizeof(candidate), "%s #%u", base, instance);
        if (!score_midi_source_name_exists(candidate)) return CFStringCreateWithCString(kCFAllocatorDefault, candidate, kCFStringEncodingUTF8);
    }
    snprintf(candidate, sizeof(candidate), "%s (%d)", base, getpid());
    return CFStringCreateWithCString(kCFAllocatorDefault, candidate, kCFStringEncodingUTF8);
}

ScoreMidiService *score_midi_create_named(const char *endpoint_name) {
    ScoreMidiService *service = (ScoreMidiService *)calloc(1, sizeof(ScoreMidiService));
    if (service == NULL) return NULL;
    if (MIDIClientCreate(CFSTR("Score"), NULL, NULL, &service->client) != noErr) goto fail;
    CFStringRef unique_name = score_midi_unique_endpoint_name(endpoint_name);
    if (unique_name == NULL) goto fail;
    const OSStatus source_status = MIDISourceCreate(service->client, unique_name, &service->virtual_source);
    CFRelease(unique_name);
    if (source_status != noErr) goto fail;
    if (MIDIInputPortCreate(service->client, CFSTR("Score Input"), score_midi_read, service, &service->input_port) != noErr) goto fail;
    if (MIDIOutputPortCreate(service->client, CFSTR("Score Output"), &service->output_port) != noErr) goto fail;
    ItemCount sources = score_midi_external_source_count(service);
    for (ItemCount index = 0; index < sources; ++index) {
        MIDIEndpointRef source = score_midi_external_source_at(service, index);
        if (source != 0) MIDIPortConnectSource(service->input_port, source, (void *)(uintptr_t)(index + 1));
    }
    service->selected_source = SCORE_MIDI_ALL_SOURCES;
    return service;
fail:
    score_midi_destroy(service);
    return NULL;
}

ScoreMidiService *score_midi_create(void) {
    return score_midi_create_named("Score Controller — Mac");
}

void score_midi_destroy(ScoreMidiService *service) {
    if (service == NULL) return;
    if (service->input_port != 0) MIDIPortDispose(service->input_port);
    if (service->output_port != 0) MIDIPortDispose(service->output_port);
    if (service->virtual_source != 0) MIDIEndpointDispose(service->virtual_source);
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
    if (service->virtual_source != 0) MIDIReceived(service->virtual_source, packets);
    ItemCount destinations = MIDIGetNumberOfDestinations();
    for (ItemCount index = 0; index < destinations; ++index) {
        MIDIEndpointRef destination = MIDIGetDestination(index);
        if (destination != 0) MIDISend(service->output_port, destination, packets);
    }
}

uint32_t score_midi_source_count(const ScoreMidiService *service) {
    return service == NULL ? 0 : (uint32_t)score_midi_external_source_count(service);
}

uint32_t score_midi_destination_count(const ScoreMidiService *service) {
    return service == NULL ? 0 : (uint32_t)MIDIGetNumberOfDestinations();
}

static size_t score_copy_cfstring(CFStringRef value, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) return 0;
    buffer[0] = '\0';
    if (value == NULL || !CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8)) return 0;
    return strlen(buffer);
}

size_t score_midi_source_name(const ScoreMidiService *service, uint32_t index, char *buffer, size_t capacity) {
    (void)service;
    if (buffer == NULL || capacity == 0 || service == NULL || index >= score_midi_external_source_count(service)) return 0;
    MIDIEndpointRef source = score_midi_external_source_at(service, (ItemCount)index);
    if (source == 0) return 0;
    CFStringRef name = NULL;
    if (MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name) != noErr || name == NULL) {
        if (MIDIObjectGetStringProperty(source, kMIDIPropertyName, &name) != noErr || name == NULL) return 0;
    }
    size_t length = score_copy_cfstring(name, buffer, capacity);
    CFRelease(name);
    return length;
}

uint32_t score_midi_selected_source(const ScoreMidiService *service) {
    return service == NULL ? SCORE_MIDI_ALL_SOURCES : service->selected_source;
}

int score_midi_select_source(ScoreMidiService *service, uint32_t index) {
    if (service == NULL || service->input_port == 0) return 0;
    ItemCount sources = score_midi_external_source_count(service);
    if (index != SCORE_MIDI_ALL_SOURCES && index >= sources) return 0;
    ItemCount all_sources = MIDIGetNumberOfSources();
    for (ItemCount source_index = 0; source_index < all_sources; ++source_index) {
        MIDIEndpointRef source = MIDIGetSource(source_index);
        if (source != 0 && source != service->virtual_source) MIDIPortDisconnectSource(service->input_port, source);
    }
    memset(service->running_status, 0, sizeof(service->running_status));
    uint32_t write = atomic_load_explicit(&service->write_index, memory_order_acquire);
    atomic_store_explicit(&service->read_index, write, memory_order_release);
    for (ItemCount source_index = 0; source_index < sources; ++source_index) {
        if (index != SCORE_MIDI_ALL_SOURCES && source_index != index) continue;
        MIDIEndpointRef source = score_midi_external_source_at(service, source_index);
        if (source != 0 && MIDIPortConnectSource(service->input_port, source, (void *)(uintptr_t)(source_index + 1)) != noErr) return 0;
    }
    service->selected_source = index;
    return 1;
}

struct ScoreAudioOutput {
    AudioComponentInstance unit;
    AudioDeviceID device;
    ScoreAudioRenderProc render;
    void *context;
    double sample_rate;
    double device_sample_rate;
    double unit_device_sample_rate;
    uint32_t unit_device_channels;
    double unit_latency_seconds;
    uint32_t device_buffer_frames;
    uint32_t device_latency_frames;
    uint32_t safety_offset_frames;
    uint32_t device_muted;
    float device_volume;
    _Atomic uint32_t callback_frames;
    _Atomic uint32_t max_callback_frames;
    _Atomic uint32_t callback_buffers;
    _Atomic uint32_t callback_channels;
    _Atomic uint64_t nonzero_samples;
    _Atomic uint32_t callback_peak_bits;
    float *scratch;
    uint32_t scratch_frames;
    uint32_t selected_device;
};

static AudioDeviceID score_default_output_device(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return kAudioObjectUnknown;
    return device;
}

static AudioDeviceID score_default_input_device(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return kAudioObjectUnknown;
    return device;
}

static uint32_t score_audio_device_input_channels(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) return 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size < sizeof(AudioBufferList)) return 0;
    AudioBufferList *buffers = (AudioBufferList *)malloc(size);
    if (buffers == NULL) return 0;
    uint32_t channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers) == noErr) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) channels += buffers->mBuffers[index].mNumberChannels;
    }
    free(buffers);
    return channels;
}

static uint32_t score_audio_device_output_channels(AudioDeviceID device) {
    if (device == kAudioObjectUnknown) return 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size < sizeof(AudioBufferList)) return 0;
    AudioBufferList *buffers = (AudioBufferList *)malloc(size);
    if (buffers == NULL) return 0;
    uint32_t channels = 0;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers) == noErr) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) channels += buffers->mBuffers[index].mNumberChannels;
    }
    free(buffers);
    return channels;
}

static AudioDeviceID score_audio_input_device_at(uint32_t requested_index) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) return kAudioObjectUnknown;
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (devices == NULL) return kAudioObjectUnknown;
    AudioDeviceID result = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        const UInt32 count = size / sizeof(AudioDeviceID);
        uint32_t input_index = 0;
        for (UInt32 index = 0; index < count; ++index) {
            if (score_audio_device_input_channels(devices[index]) == 0) continue;
            if (input_index == requested_index) {
                result = devices[index];
                break;
            }
            input_index += 1;
        }
    }
    free(devices);
    return result;
}

static AudioDeviceID score_audio_output_device_at(uint32_t requested_index) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) return kAudioObjectUnknown;
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (devices == NULL) return kAudioObjectUnknown;
    AudioDeviceID result = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        const UInt32 count = size / sizeof(AudioDeviceID);
        uint32_t output_index = 0;
        for (UInt32 index = 0; index < count; ++index) {
            if (score_audio_device_output_channels(devices[index]) == 0) continue;
            if (output_index == requested_index) {
                result = devices[index];
                break;
            }
            output_index += 1;
        }
    }
    free(devices);
    return result;
}

uint32_t score_audio_output_device_count(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (devices == NULL) return 0;
    uint32_t result = 0;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        const UInt32 count = size / sizeof(AudioDeviceID);
        for (UInt32 index = 0; index < count; ++index) if (score_audio_device_output_channels(devices[index]) != 0) result += 1;
    }
    free(devices);
    return result;
}

uint32_t score_audio_default_output_index(void) {
    const AudioDeviceID default_device = score_default_output_device();
    const uint32_t count = score_audio_output_device_count();
    for (uint32_t index = 0; index < count; ++index) if (score_audio_output_device_at(index) == default_device) return index;
    return SCORE_AUDIO_DEFAULT_DEVICE;
}

size_t score_audio_output_device_name(uint32_t index, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) return 0;
    buffer[0] = '\0';
    const AudioDeviceID device = score_audio_output_device_at(index);
    if (device == kAudioObjectUnknown) return 0;
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || name == NULL) return 0;
    size_t length = score_copy_cfstring(name, buffer, capacity);
    CFRelease(name);
    return length;
}

uint32_t score_audio_input_device_count(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioDeviceID *devices = (AudioDeviceID *)malloc(size);
    if (devices == NULL) return 0;
    uint32_t result = 0;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        const UInt32 count = size / sizeof(AudioDeviceID);
        for (UInt32 index = 0; index < count; ++index) if (score_audio_device_input_channels(devices[index]) != 0) result += 1;
    }
    free(devices);
    return result;
}

uint32_t score_audio_default_input_index(void) {
    const AudioDeviceID default_device = score_default_input_device();
    const uint32_t count = score_audio_input_device_count();
    for (uint32_t index = 0; index < count; ++index) if (score_audio_input_device_at(index) == default_device) return index;
    return SCORE_AUDIO_DEFAULT_DEVICE;
}

size_t score_audio_input_device_name(uint32_t index, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) return 0;
    buffer[0] = '\0';
    const AudioDeviceID device = score_audio_input_device_at(index);
    if (device == kAudioObjectUnknown) return 0;
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || name == NULL) return 0;
    size_t length = score_copy_cfstring(name, buffer, capacity);
    CFRelease(name);
    return length;
}

size_t score_audio_default_input_name(char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) return 0;
    buffer[0] = '\0';
    AudioDeviceID device = score_default_input_device();
    if (device == kAudioObjectUnknown) return 0;
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || name == NULL) return 0;
    size_t length = score_copy_cfstring(name, buffer, capacity);
    CFRelease(name);
    return length;
}

static uint32_t score_output_device_u32(AudioDeviceID device, AudioObjectPropertySelector selector) {
    if (device == kAudioObjectUnknown) return 0;
    uint32_t value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return 0;
    return value;
}

static double score_output_device_f64(AudioDeviceID device, AudioObjectPropertySelector selector) {
    if (device == kAudioObjectUnknown) return 0.0;
    double value = 0.0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return 0.0;
    return value;
}

double score_audio_output_device_nominal_sample_rate(uint32_t index) {
    const AudioDeviceID device = score_audio_output_device_at(index);
    return score_output_device_f64(device, kAudioDevicePropertyNominalSampleRate);
}

static float score_output_device_f32(AudioDeviceID device, AudioObjectPropertySelector selector, float fallback) {
    if (device == kAudioObjectUnknown) return fallback;
    float value = fallback;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return fallback;
    return value;
}

static uint32_t score_input_device_u32(AudioDeviceID device, AudioObjectPropertySelector selector) {
    if (device == kAudioObjectUnknown) return 0;
    uint32_t value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return 0;
    return value;
}

static double score_input_device_f64(AudioDeviceID device, AudioObjectPropertySelector selector) {
    if (device == kAudioObjectUnknown) return 0.0;
    double value = 0.0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) return 0.0;
    return value;
}

static OSStatus score_audio_render_callback(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
    (void)flags;
    (void)timestamp;
    (void)bus;
    ScoreAudioOutput *output = (ScoreAudioOutput *)context;
    if (output == NULL || output->render == NULL || buffers == NULL) return noErr;
    if (frames > output->scratch_frames) frames = output->scratch_frames;
    atomic_store_explicit(&output->callback_frames, frames, memory_order_release);
    uint32_t maximum = atomic_load_explicit(&output->max_callback_frames, memory_order_relaxed);
    while (frames > maximum && !atomic_compare_exchange_weak_explicit(&output->max_callback_frames, &maximum, frames, memory_order_release, memory_order_relaxed)) {}
    output->render(output->scratch, frames, 2, output->sample_rate, output->context);

    uint64_t nonzero_samples = 0;
    float callback_peak = 0.0f;
    for (UInt32 sample_index = 0; sample_index < frames * 2; ++sample_index) {
        const float sample = output->scratch[sample_index];
        if (sample != 0.0f) nonzero_samples += 1;
        const float magnitude = sample < 0.0f ? -sample : sample;
        if (magnitude > callback_peak) callback_peak = magnitude;
    }
    uint32_t callback_peak_bits = 0;
    memcpy(&callback_peak_bits, &callback_peak, sizeof(callback_peak_bits));
    atomic_fetch_add_explicit(&output->nonzero_samples, nonzero_samples, memory_order_relaxed);
    atomic_store_explicit(&output->callback_peak_bits, callback_peak_bits, memory_order_release);

    // CoreAudio may expose stereo as one interleaved buffer, two mono
    // buffers, or as the first two channels of a larger interleaved device
    // (for example BlackHole 16ch). Treat every AudioBuffer as an
    // interleaved group and map the rendered stereo pair to the first two
    // device channels. Unused channels must be cleared: leaving callback
    // memory untouched can feed stale samples to a multichannel interface.
    UInt32 first_device_channel = 0;
    atomic_store_explicit(&output->callback_buffers, buffers->mNumberBuffers, memory_order_release);
    for (UInt32 buffer_index = 0; buffer_index < buffers->mNumberBuffers; ++buffer_index) {
        AudioBuffer *buffer = &buffers->mBuffers[buffer_index];
        const UInt32 channels = buffer->mNumberChannels;
        if (buffer->mData == NULL || channels == 0) {
            first_device_channel += channels;
            continue;
        }

        memset(buffer->mData, 0, buffer->mDataByteSize);
        const UInt32 available_frames = buffer->mDataByteSize / (channels * sizeof(float));
        const UInt32 mapped_frames = frames < available_frames ? frames : available_frames;
        float *destination = (float *)buffer->mData;
        for (UInt32 frame = 0; frame < mapped_frames; ++frame) {
            for (UInt32 local_channel = 0; local_channel < channels; ++local_channel) {
                const UInt32 device_channel = first_device_channel + local_channel;
                if (device_channel < 2) {
                    destination[frame * channels + local_channel] = output->scratch[frame * 2 + device_channel];
                }
            }
        }
        first_device_channel += channels;
    }
    atomic_store_explicit(&output->callback_channels, first_device_channel, memory_order_release);
    return noErr;
}

ScoreAudioOutput *score_audio_output_start_device(ScoreAudioRenderProc render, void *context, uint32_t device_index) {
    const bool explicit_device = device_index != SCORE_AUDIO_DEFAULT_DEVICE;
    AudioComponentDescription description = {kAudioUnitType_Output, explicit_device ? kAudioUnitSubType_HALOutput : kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
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
    const AudioDeviceID device = explicit_device ? score_audio_output_device_at(device_index) : score_default_output_device();
    if (device == kAudioObjectUnknown) goto fail;
    output->device = device;
    const double nominal_sample_rate = score_output_device_f64(device, kAudioDevicePropertyNominalSampleRate);
    if (explicit_device && nominal_sample_rate > 0.0) output->sample_rate = nominal_sample_rate;
    if (explicit_device) {
        UInt32 enable_output = 1;
        UInt32 disable_input = 0;
        if (AudioUnitSetProperty(output->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable_output, sizeof(enable_output)) != noErr) goto fail;
        if (AudioUnitSetProperty(output->unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable_input, sizeof(disable_input)) != noErr) goto fail;
        if (AudioUnitSetProperty(output->unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device)) != noErr) goto fail;
    }
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
    AudioStreamBasicDescription unit_device_format = {0};
    UInt32 unit_device_format_size = sizeof(unit_device_format);
    if (AudioUnitGetProperty(output->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &unit_device_format, &unit_device_format_size) == noErr) {
        output->unit_device_sample_rate = unit_device_format.mSampleRate;
        output->unit_device_channels = unit_device_format.mChannelsPerFrame;
    }
    UInt32 latency_size = sizeof(output->unit_latency_seconds);
    if (AudioUnitGetProperty(output->unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &output->unit_latency_seconds, &latency_size) != noErr) output->unit_latency_seconds = 0.0;
    output->selected_device = explicit_device ? device_index : score_audio_default_output_index();
    output->device_sample_rate = score_output_device_f64(device, kAudioDevicePropertyNominalSampleRate);
    if (output->device_sample_rate <= 0.0) output->device_sample_rate = output->sample_rate;
    output->device_buffer_frames = score_output_device_u32(device, kAudioDevicePropertyBufferFrameSize);
    output->device_latency_frames = score_output_device_u32(device, kAudioDevicePropertyLatency);
    output->safety_offset_frames = score_output_device_u32(device, kAudioDevicePropertySafetyOffset);
    output->device_muted = score_output_device_u32(device, kAudioDevicePropertyMute);
    output->device_volume = score_output_device_f32(device, kAudioDevicePropertyVolumeScalar, 1.0f);
    if (AudioOutputUnitStart(output->unit) != noErr) goto fail;
    return output;
fail:
    score_audio_output_stop(output);
    return NULL;
}

ScoreAudioOutput *score_audio_output_start(ScoreAudioRenderProc render, void *context) {
    return score_audio_output_start_device(render, context, SCORE_AUDIO_DEFAULT_DEVICE);
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

uint32_t score_audio_output_selected_device(const ScoreAudioOutput *output) {
    return output == NULL ? SCORE_AUDIO_DEFAULT_DEVICE : output->selected_device;
}

double score_audio_output_sample_rate(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0 : output->sample_rate;
}

double score_audio_output_device_sample_rate(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0 : output->device_sample_rate;
}

double score_audio_output_unit_device_sample_rate(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0 : output->unit_device_sample_rate;
}

uint32_t score_audio_output_unit_device_channels(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : output->unit_device_channels;
}

uint32_t score_audio_output_device_buffer_frames(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : output->device_buffer_frames;
}

uint32_t score_audio_output_device_latency_frames(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : output->device_latency_frames;
}

uint32_t score_audio_output_safety_offset_frames(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : output->safety_offset_frames;
}

uint32_t score_audio_output_callback_frames(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : atomic_load_explicit(&output->callback_frames, memory_order_acquire);
}

uint32_t score_audio_output_max_callback_frames(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : atomic_load_explicit(&output->max_callback_frames, memory_order_acquire);
}

uint32_t score_audio_output_callback_buffers(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : atomic_load_explicit(&output->callback_buffers, memory_order_acquire);
}

uint32_t score_audio_output_callback_channels(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : atomic_load_explicit(&output->callback_channels, memory_order_acquire);
}

uint64_t score_audio_output_nonzero_samples(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : atomic_load_explicit(&output->nonzero_samples, memory_order_acquire);
}

float score_audio_output_callback_peak(const ScoreAudioOutput *output) {
    if (output == NULL) return 0.0f;
    const uint32_t bits = atomic_load_explicit(&output->callback_peak_bits, memory_order_acquire);
    float result = 0.0f;
    memcpy(&result, &bits, sizeof(result));
    return result;
}

uint32_t score_audio_output_device_muted(const ScoreAudioOutput *output) {
    return output == NULL ? 0 : score_output_device_u32(output->device, kAudioDevicePropertyMute);
}

float score_audio_output_device_volume(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0f : score_output_device_f32(output->device, kAudioDevicePropertyVolumeScalar, output->device_volume);
}

uint32_t score_audio_output_device_input_muted(const ScoreAudioOutput *output) {
    if (output == NULL || output->device == kAudioObjectUnknown) return 0;
    uint32_t value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(output->device, &address, 0, NULL, &size, &value) != noErr) return 0;
    return value;
}

float score_audio_output_device_input_volume(const ScoreAudioOutput *output) {
    if (output == NULL || output->device == kAudioObjectUnknown) return 1.0f;
    float value = 1.0f;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(output->device, &address, 0, NULL, &size, &value) != noErr) return 1.0f;
    return value;
}

int score_audio_output_set_muted(ScoreAudioOutput *output, int muted) {
    if (output == NULL || output->device == kAudioObjectUnknown) return 0;
    const uint32_t value = muted != 0 ? 1 : 0;
    AudioObjectPropertyAddress address = {kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    if (!AudioObjectHasProperty(output->device, &address)) return 0;
    if (AudioObjectSetPropertyData(output->device, &address, 0, NULL, sizeof(value), &value) != noErr) return 0;
    output->device_muted = value;
    return 1;
}

double score_audio_output_unit_latency_seconds(const ScoreAudioOutput *output) {
    return output == NULL ? 0.0 : output->unit_latency_seconds;
}

double score_audio_output_estimated_latency_seconds(const ScoreAudioOutput *output) {
    if (output == NULL || output->device_sample_rate <= 0.0) return 0.0;
    const double device_frames = (double)output->device_buffer_frames + (double)output->device_latency_frames + (double)output->safety_offset_frames;
    return output->unit_latency_seconds + device_frames / output->device_sample_rate;
}

struct ScoreAudioInput {
    AudioQueueRef queue;
    AudioQueueBufferRef buffers[3];
    AudioStreamBasicDescription format;
    ScoreAudioInputProc input;
    void *context;
    AudioFileID recording;
    SInt64 packet_position;
    double device_sample_rate;
    uint32_t device_buffer_frames;
    uint32_t device_latency_frames;
    uint32_t safety_offset_frames;
    _Atomic uint32_t callback_frames;
    _Atomic uint32_t max_callback_frames;
    uint32_t selected_device;
};

static void score_audio_input_callback(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *start_time, UInt32 packet_count, const AudioStreamPacketDescription *descriptions) {
    (void)descriptions;
    ScoreAudioInput *input = (ScoreAudioInput *)context;
    if (input == NULL || buffer == NULL) return;
    UInt32 frames = buffer->mAudioDataByteSize / sizeof(float);
    atomic_store_explicit(&input->callback_frames, frames, memory_order_release);
    uint32_t maximum = atomic_load_explicit(&input->max_callback_frames, memory_order_relaxed);
    while (frames > maximum && !atomic_compare_exchange_weak_explicit(&input->max_callback_frames, &maximum, frames, memory_order_release, memory_order_relaxed)) {}
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

ScoreAudioInput *score_audio_input_start_device(ScoreAudioInputProc input_proc, void *context, uint32_t device_index) {
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
    const AudioDeviceID device = device_index == SCORE_AUDIO_DEFAULT_DEVICE ? score_default_input_device() : score_audio_input_device_at(device_index);
    if (device == kAudioObjectUnknown) goto fail;
    CFStringRef device_uid = NULL;
    UInt32 uid_size = sizeof(device_uid);
    AudioObjectPropertyAddress uid_address = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(device, &uid_address, 0, NULL, &uid_size, &device_uid) != noErr || device_uid == NULL) goto fail;
    const OSStatus select_status = AudioQueueSetProperty(input->queue, kAudioQueueProperty_CurrentDevice, &device_uid, sizeof(device_uid));
    CFRelease(device_uid);
    if (select_status != noErr) goto fail;
    input->selected_device = device_index == SCORE_AUDIO_DEFAULT_DEVICE ? score_audio_default_input_index() : device_index;
    input->device_sample_rate = score_input_device_f64(device, kAudioDevicePropertyNominalSampleRate);
    if (input->device_sample_rate <= 0.0) input->device_sample_rate = input->format.mSampleRate;
    input->device_buffer_frames = score_input_device_u32(device, kAudioDevicePropertyBufferFrameSize);
    input->device_latency_frames = score_input_device_u32(device, kAudioDevicePropertyLatency);
    input->safety_offset_frames = score_input_device_u32(device, kAudioDevicePropertySafetyOffset);
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

ScoreAudioInput *score_audio_input_start(ScoreAudioInputProc input_proc, void *context) {
    return score_audio_input_start_device(input_proc, context, SCORE_AUDIO_DEFAULT_DEVICE);
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

uint32_t score_audio_input_selected_device(const ScoreAudioInput *input) {
    return input == NULL ? SCORE_AUDIO_DEFAULT_DEVICE : input->selected_device;
}

double score_audio_input_sample_rate(const ScoreAudioInput *input) {
    return input == NULL ? 0.0 : input->format.mSampleRate;
}

double score_audio_input_device_sample_rate(const ScoreAudioInput *input) {
    return input == NULL ? 0.0 : input->device_sample_rate;
}

uint32_t score_audio_input_device_buffer_frames(const ScoreAudioInput *input) {
    return input == NULL ? 0 : input->device_buffer_frames;
}

uint32_t score_audio_input_device_latency_frames(const ScoreAudioInput *input) {
    return input == NULL ? 0 : input->device_latency_frames;
}

uint32_t score_audio_input_safety_offset_frames(const ScoreAudioInput *input) {
    return input == NULL ? 0 : input->safety_offset_frames;
}

uint32_t score_audio_input_callback_frames(const ScoreAudioInput *input) {
    return input == NULL ? 0 : atomic_load_explicit(&input->callback_frames, memory_order_acquire);
}

uint32_t score_audio_input_max_callback_frames(const ScoreAudioInput *input) {
    return input == NULL ? 0 : atomic_load_explicit(&input->max_callback_frames, memory_order_acquire);
}

double score_audio_input_estimated_latency_seconds(const ScoreAudioInput *input) {
    if (input == NULL || input->device_sample_rate <= 0.0 || input->format.mSampleRate <= 0.0) return 0.0;
    const double device_frames = (double)input->device_buffer_frames + (double)input->device_latency_frames + (double)input->safety_offset_frames;
    const double analysis_frames = (double)atomic_load_explicit(&input->callback_frames, memory_order_acquire) * 0.5;
    return device_frames / input->device_sample_rate + analysis_frames / input->format.mSampleRate;
}
