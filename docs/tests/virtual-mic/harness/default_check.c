// rd-default-check: with Remote Display Microphone installed, checks what decision 0031
// expects of it. It can be the default input; neither it nor its hidden feeder can be
// the default output; the feeder isn't listed. Each default it changes is put back.
// Needs no microphone access: it only reads and sets devices' properties.
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

#define MIC_UID "RemoteDisplayMicrophone_UID"
#define FEEDER_UID "RemoteDisplayMicrophone_2_UID"

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
    return a;
}

static AudioObjectID device_for_uid(const char* uid) {
    CFStringRef s = CFStringCreateWithCString(NULL, uid, kCFStringEncodingUTF8);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof s, &s, &size, &dev);
    CFRelease(s);
    return dev;
}

static UInt32 u32(AudioObjectID obj, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = addr(sel, scope);
    UInt32 v = 0, size = sizeof v;
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &v) ? 0 : v;
}

static UInt32 streams(AudioObjectID dev, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = addr(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(dev, &a, 0, NULL, &size) ? 0 : size / sizeof(AudioObjectID);
}

static void name(AudioObjectID dev, char* out, size_t len) {
    AudioObjectPropertyAddress a = addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal);
    CFStringRef s = NULL;
    UInt32 size = sizeof s;
    out[0] = 0;
    if (!AudioObjectGetPropertyData(dev, &a, 0, NULL, &size, &s) && s) {
        CFStringGetCString(s, out, len, kCFStringEncodingUTF8);
        CFRelease(s);
    }
}

static AudioObjectID get_default(AudioObjectPropertySelector which) {
    AudioObjectPropertyAddress a = addr(which, kAudioObjectPropertyScopeGlobal);
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &dev);
    return dev;
}

static OSStatus set_default(AudioObjectPropertySelector which, AudioObjectID dev) {
    AudioObjectPropertyAddress a = addr(which, kAudioObjectPropertyScopeGlobal);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof dev, &dev);
}

// Tries `dev` as the default `which`, reads back what's default, and restores the old one.
// Returns whether `dev` became the default.
static int try_default(const char* what, AudioObjectPropertySelector which, AudioObjectID dev) {
    AudioObjectID before = get_default(which);
    OSStatus st = set_default(which, dev);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    AudioObjectID now = get_default(which);
    int took = now == dev;
    if (now != before) set_default(which, before);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    printf("  %s: set returned %d, %s; default is back to device %u\n", what, (int)st,
           took ? "it became the default" : "the default didn't change", get_default(which));
    return took;
}

int main(void) {
    AudioObjectID mic = device_for_uid(MIC_UID), feeder = device_for_uid(FEEDER_UID);
    if (mic == kAudioObjectUnknown || feeder == kAudioObjectUnknown) {
        printf("Remote Display Microphone isn't installed (mic %u, feeder %u)\n", mic, feeder);
        return 2;
    }

    AudioObjectPropertyAddress a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size);
    AudioObjectID* devs = malloc(size);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devs);
    int listed_mic = 0, listed_feeder = 0;
    printf("Devices (in/out streams, can be default input/output):\n");
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        char n[256];
        name(devs[i], n, sizeof n);
        printf("  %-32s in=%u out=%u default-in=%u default-out=%u\n", n,
               streams(devs[i], kAudioObjectPropertyScopeInput), streams(devs[i], kAudioObjectPropertyScopeOutput),
               u32(devs[i], kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeInput),
               u32(devs[i], kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput));
        listed_mic |= devs[i] == mic;
        listed_feeder |= devs[i] == feeder;
    }
    free(devs);

    printf("Checks:\n");
    int ok = 1;
    printf("  the microphone is listed: %s\n", listed_mic ? "yes" : "NO");
    ok &= listed_mic;
    printf("  the feeder is hidden from the list: %s\n", listed_feeder ? "NO" : "yes");
    ok &= !listed_feeder;
    ok &= try_default("microphone as the default input", kAudioHardwarePropertyDefaultInputDevice, mic);
    ok &= !try_default("microphone as the default output", kAudioHardwarePropertyDefaultOutputDevice, mic);
    ok &= !try_default("feeder as the default output", kAudioHardwarePropertyDefaultOutputDevice, feeder);
    ok &= !try_default("feeder as the system output", kAudioHardwarePropertyDefaultSystemOutputDevice, feeder);
    printf("%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
