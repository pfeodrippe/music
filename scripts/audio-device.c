#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int device_name(AudioDeviceID device, char *buffer, size_t capacity) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || name == NULL) return 0;
    const Boolean ok = CFStringGetCString(name, buffer, capacity, kCFStringEncodingUTF8);
    CFRelease(name);
    return ok != 0;
}

static AudioDeviceID find_device(const char *wanted) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) return kAudioObjectUnknown;
    AudioDeviceID *devices = malloc(size);
    if (devices == NULL) return kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return kAudioObjectUnknown;
    }
    AudioDeviceID result = kAudioObjectUnknown;
    const size_t count = size / sizeof(*devices);
    for (size_t index = 0; index < count; ++index) {
        char name[256] = {0};
        if (!device_name(devices[index], name, sizeof(name))) continue;
        if (wanted == NULL) printf("%u\t%s\n", devices[index], name);
        if (wanted != NULL && strcmp(name, wanted) == 0) {
            result = devices[index];
            break;
        }
    }
    free(devices);
    return result;
}

static AudioDeviceID default_output(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return kAudioObjectUnknown;
    return device;
}

static int set_default_output(AudioDeviceID device) {
    const AudioObjectPropertySelector selectors[] = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    };
    for (size_t index = 0; index < sizeof(selectors) / sizeof(selectors[0]); ++index) {
        AudioObjectPropertyAddress address = {
            selectors[index],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain,
        };
        if (AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(device), &device) != noErr) return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "list") == 0) {
        (void)find_device(NULL);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "get") == 0) {
        char name[256] = {0};
        const AudioDeviceID device = default_output();
        if (device == kAudioObjectUnknown || !device_name(device, name, sizeof(name))) return 2;
        puts(name);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "set") == 0) {
        const AudioDeviceID device = find_device(argv[2]);
        if (device == kAudioObjectUnknown) return 3;
        return set_default_output(device) ? 0 : 4;
    }
    fprintf(stderr, "usage: %s list | get | set DEVICE_NAME\n", argv[0]);
    return 1;
}
