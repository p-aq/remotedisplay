// rd-voice-probe: measures Apple's voice processing (AVAudioEngine's input node), which
// the spec names for the controller's echo (decision 0023), on the Mac's own devices:
//
//   - which input it records from when another one is picked, and whether it runs with the
//     input and output on different devices;
//   - how much of a voice played through the speaker it takes out when the voice plays
//     through its own engine, through another output in the same process (how the engine
//     plays the host's sound) and from another process;
//   - how much it lowers ("ducks") the other audio, and whether the minimum ducking helps.
//
// Speech, not a tone: voice processing also suppresses steady noise, which a tone is.
// Each step records the voice-processed input and, at the same time, the same input
// without processing, so what voice processing removed is the difference between the two.
// See ../README.md.
//
//   rd-voice-probe --mic NAME --speaker NAME --speech FILE [--pick after,before,input,none]
//   rd-voice-probe --list                                       the devices, no microphone
//   rd-voice-probe --play SPEAKER --speech FILE --seconds S     the "other process"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>

#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

extern char** environ;

static const double kRate = 48000;

// ---- Devices

static std::vector<AudioDeviceID> allDevices() {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, nullptr, &size);
    std::vector<AudioDeviceID> ids(size / sizeof(AudioDeviceID));
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, ids.data());
    return ids;
}

static std::string deviceName(AudioDeviceID id) {
    if (id == kAudioObjectUnknown) return "(none)";
    AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    CFStringRef name = nullptr;
    UInt32 size = sizeof(name);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &name) != noErr || !name) return "?";
    std::string out = [(__bridge NSString*)name UTF8String];
    CFRelease(name);
    return out;
}

static NSString* deviceUID(AudioDeviceID id) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    CFStringRef uid = nullptr;
    UInt32 size = sizeof(uid);
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString*)uid;
}

static UInt32 channels(AudioDeviceID id, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, scope,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(id, &a, 0, nullptr, &size) != noErr || size == 0) return 0;
    std::vector<uint8_t> buf(size);
    auto* list = reinterpret_cast<AudioBufferList*>(buf.data());
    if (AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, list) != noErr) return 0;
    UInt32 n = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) n += list->mBuffers[i].mNumberChannels;
    return n;
}

static AudioDeviceID defaultDevice(AudioObjectPropertySelector which) {
    AudioObjectPropertyAddress a = {which, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioDeviceID id = kAudioObjectUnknown;
    UInt32 size = sizeof(id);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &size, &id);
    return id;
}

static AudioDeviceID deviceNamed(const std::string& name, AudioObjectPropertyScope scope) {
    for (AudioDeviceID id : allDevices())
        if (channels(id, scope) > 0 && deviceName(id) == name) return id;
    return kAudioObjectUnknown;
}

static bool runningSomewhere(AudioDeviceID id) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceIsRunningSomewhere,
                                    kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 running = 0, size = sizeof(running);
    AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &running);
    return running != 0;
}

// The output's volume (main element, else the first channel's) and whether it's muted.
static void outputVolume(AudioDeviceID id, float* volume, bool* muted) {
    *volume = -1;
    *muted = false;
    for (UInt32 element : {0u, 1u}) {
        AudioObjectPropertyAddress a = {kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput,
                                        element};
        Float32 v = 0;
        UInt32 size = sizeof(v);
        if (AudioObjectHasProperty(id, &a) &&
            AudioObjectGetPropertyData(id, &a, 0, nullptr, &size, &v) == noErr) {
            *volume = v;
            break;
        }
    }
    AudioObjectPropertyAddress m = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, 0};
    UInt32 mute = 0, size = sizeof(mute);
    if (AudioObjectHasProperty(id, &m) &&
        AudioObjectGetPropertyData(id, &m, 0, nullptr, &size, &mute) == noErr)
        *muted = mute != 0;
}

static void listDevices() {
    AudioDeviceID in = defaultDevice(kAudioHardwarePropertyDefaultInputDevice);
    AudioDeviceID out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
    for (AudioDeviceID id : allDevices()) {
        UInt32 i = channels(id, kAudioObjectPropertyScopeInput);
        UInt32 o = channels(id, kAudioObjectPropertyScopeOutput);
        printf("  %-36s in %u, out %u%s%s%s\n", deviceName(id).c_str(), i, o,
               id == in ? ", default input" : "", id == out ? ", default output" : "",
               runningSomewhere(id) ? ", running" : "");
    }
}

// ---- Recording and the levels of a span of it

struct Recording {
    std::mutex lock;
    std::vector<float> samples;
    double rate = kRate;

    void add(const float* p, size_t n) {
        std::lock_guard<std::mutex> g(lock);
        samples.insert(samples.end(), p, p + n);
    }
    size_t now() {
        std::lock_guard<std::mutex> g(lock);
        return samples.size();
    }
    // RMS of [from, to), as dBFS.
    double db(size_t from, size_t to) {
        std::lock_guard<std::mutex> g(lock);
        to = std::min(to, samples.size());
        if (from >= to) return -200;
        double sum = 0;
        for (size_t i = from; i < to; i++) sum += (double)samples[i] * samples[i];
        return 10 * log10(std::max(sum / (to - from), 1e-20));
    }
    size_t seconds(double s) { return (size_t)(s * rate); }
};

// What a voice added over the room, in dB: the power of the two subtracted.
static double over(double withVoice, double room) {
    double p = pow(10, withVoice / 10) - pow(10, room / 10);
    return p > 0 ? 10 * log10(p) : -200;
}

// ---- The input without voice processing: an audio queue on the device, 48 kHz mono

static AudioStreamBasicDescription monoFloat() {
    AudioStreamBasicDescription f = {};
    f.mSampleRate = kRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 32;
    f.mBytesPerFrame = f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    return f;
}

struct PlainInput {
    AudioQueueRef queue = nullptr;
    Recording rec;

    static void filled(void* ctx, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp*,
                       UInt32, const AudioStreamPacketDescription*) {
        auto* self = static_cast<PlainInput*>(ctx);
        self->rec.add(static_cast<const float*>(b->mAudioData), b->mAudioDataByteSize / 4);
        AudioQueueEnqueueBuffer(q, b, 0, nullptr);
    }

    bool start(AudioDeviceID device) {
        AudioStreamBasicDescription f = monoFloat();
        OSStatus s = AudioQueueNewInput(&f, filled, this, nullptr, nullptr, 0, &queue);
        NSString* uidString = deviceUID(device);
        CFStringRef uid = (__bridge CFStringRef)uidString;
        if (s == noErr) s = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
        for (int i = 0; s == noErr && i < 4; i++) {
            AudioQueueBufferRef b;
            s = AudioQueueAllocateBuffer(queue, 4800 * 4, &b);
            if (s == noErr) s = AudioQueueEnqueueBuffer(queue, b, 0, nullptr);
        }
        if (s == noErr) s = AudioQueueStart(queue, nullptr);
        if (s != noErr) printf("plain input didn't start: %d\n", (int)s);
        return s == noErr;
    }
    void stop() {
        if (!queue) return;
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
        queue = nullptr;
    }
};

// ---- The voice, through another output: an audio queue on the speaker, looping

struct SpeechOutput {
    AudioQueueRef queue = nullptr;
    const std::vector<float>* speech = nullptr;
    size_t at = 0;

    static void empty(void* ctx, AudioQueueRef q, AudioQueueBufferRef b) {
        auto* self = static_cast<SpeechOutput*>(ctx);
        auto* out = static_cast<float*>(b->mAudioData);
        UInt32 n = b->mAudioDataBytesCapacity / 4;
        for (UInt32 i = 0; i < n; i++) {
            out[i] = (*self->speech)[self->at];
            self->at = (self->at + 1) % self->speech->size();
        }
        b->mAudioDataByteSize = n * 4;
        AudioQueueEnqueueBuffer(q, b, 0, nullptr);
    }

    bool start(AudioDeviceID device, const std::vector<float>& voice) {
        speech = &voice;
        AudioStreamBasicDescription f = monoFloat();
        OSStatus s = AudioQueueNewOutput(&f, empty, this, nullptr, nullptr, 0, &queue);
        NSString* uidString = deviceUID(device);
        CFStringRef uid = (__bridge CFStringRef)uidString;
        if (s == noErr) s = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
        for (int i = 0; s == noErr && i < 3; i++) {
            AudioQueueBufferRef b;
            s = AudioQueueAllocateBuffer(queue, 4800 * 4, &b);
            if (s == noErr) empty(this, queue, b);
        }
        if (s == noErr) s = AudioQueueStart(queue, nullptr);
        if (s != noErr) printf("speech output didn't start: %d\n", (int)s);
        return s == noErr;
    }
    void stop() {
        if (!queue) return;
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
        queue = nullptr;
    }
};

static std::vector<float> loadSpeech(NSString* path, AVAudioPCMBuffer** asBuffer) {
    NSError* err = nil;
    AVAudioFile* file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&err];
    if (!file) {
        printf("can't read %s: %s\n", path.UTF8String, err.localizedDescription.UTF8String);
        exit(2);
    }
    AVAudioFormat* format = file.processingFormat;
    if (format.sampleRate != kRate || format.channelCount != 1) {
        printf("%s isn't 48 kHz mono\n", path.UTF8String);
        exit(2);
    }
    AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                          frameCapacity:(AVAudioFrameCount)file.length];
    [file readIntoBuffer:buf error:&err];
    *asBuffer = buf;
    return std::vector<float>(buf.floatChannelData[0], buf.floatChannelData[0] + buf.frameLength);
}

static void wait(double seconds) { [NSThread sleepForTimeInterval:seconds]; }

static std::string exePath() {
    char path[4096];
    uint32_t size = sizeof(path);
    _NSGetExecutablePath(path, &size);
    return path;
}

// ---- The measurement

struct Step {
    const char* what;
    double vpRoom, vpVoice, plainRoom, plainVoice;
};

int main(int argc, char** argv) {
    @autoreleasepool {
        std::string mic, speaker, speechPath, picks = "after,before,input,none";
        double seconds = 4;
        bool list = false, play = false;
        for (int i = 1; i < argc; i++) {
            std::string a = argv[i];
            auto next = [&] { return i + 1 < argc ? std::string(argv[++i]) : std::string(); };
            if (a == "--mic") mic = next();
            else if (a == "--speaker") speaker = next();
            else if (a == "--speech") speechPath = next();
            else if (a == "--seconds") seconds = atof(next().c_str());
            else if (a == "--pick") picks = next();
            else if (a == "--list") list = true;
            else if (a == "--play") { play = true; speaker = next(); }
        }
        setvbuf(stdout, nullptr, _IOLBF, 0);
        if (list) {
            listDevices();
            return 0;
        }

        AVAudioPCMBuffer* speechBuffer = nil;
        std::vector<float> speech = loadSpeech(@(speechPath.c_str()), &speechBuffer);
        AudioDeviceID spk = speaker.empty() ? defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
                                            : deviceNamed(speaker, kAudioObjectPropertyScopeOutput);
        if (spk == kAudioObjectUnknown) {
            printf("no output named \"%s\"\n", speaker.c_str());
            return 2;
        }
        if (play) {
            SpeechOutput out;
            if (!out.start(spk, speech)) return 1;
            wait(seconds);
            out.stop();
            return 0;
        }

        AudioDeviceID in = mic.empty() ? defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
                                       : deviceNamed(mic, kAudioObjectPropertyScopeInput);
        if (in == kAudioObjectUnknown) {
            printf("no input named \"%s\"\n", mic.c_str());
            return 2;
        }
        // Without access, the inputs below hear digital silence; ask first.
        __block int answer = -1;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL granted) { answer = granted; }];
        for (int i = 0; answer < 0 && i < 3000; i++) wait(0.1);
        if (answer != 1) {
            printf("microphone access %s\n", answer < 0 ? "not answered" : "refused");
            return 1;
        }
        float volume;
        bool muted;
        outputVolume(spk, &volume, &muted);
        printf("input \"%s\", output \"%s\" (volume %.2f%s); defaults: \"%s\" in, \"%s\" out\n",
               deviceName(in).c_str(), deviceName(spk).c_str(), volume, muted ? ", muted" : "",
               deviceName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)).c_str(),
               deviceName(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)).c_str());
        printf("devices before:\n");
        listDevices();

        SpeechOutput out;

        // 1. Without voice processing: what the input hears of the speaker.
        double unprocessed;
        {
            PlainInput plain;
            if (!plain.start(in)) return 1;
            wait(1.5);
            size_t t = plain.rec.now();
            double room = plain.rec.db(t - plain.rec.seconds(1), t);
            out.start(spk, speech);
            wait(1);
            size_t from = plain.rec.now();
            wait(seconds - 1);
            double voice = plain.rec.db(from, plain.rec.now());
            out.stop();
            plain.stop();
            unprocessed = over(voice, room);
            printf("\nwithout voice processing: room %.1f dBFS, the voice %.1f dB over it\n", room,
                   unprocessed);
        }
        wait(0.5);

        // 2. Voice processing, once for each way of picking its devices:
        //    after   enable it, then set the input (element 1) and output (element 0) on its unit
        //    before  set them on the engine's plain units, then enable it
        //    input   enable it, then set only the input
        //    none    enable it and leave the system's default input and output
        SpeechOutput* o = &out;
        AudioDeviceID speakerID = spk;
        const std::vector<float>* voice = &speech;
        std::string exe = exePath(), speakerName = deviceName(spk);
        std::string secs = std::to_string(seconds + 0.5);
        auto setDevice = [](AudioUnit unit, UInt32 element, AudioDeviceID id) {
            return (int)AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                             kAudioUnitScope_Global, element, &id, sizeof(id));
        };
        for (NSString* pick in [@(picks.c_str()) componentsSeparatedByString:@","]) {
            printf("\n== voice processing, devices picked: %s\n", pick.UTF8String);
            AVAudioEngine* engine = [AVAudioEngine new];
            AVAudioInputNode* input = engine.inputNode;
            NSError* err = nil;
            if ([pick isEqualToString:@"before"]) {
                printf("picking the input: %d, the output: %d\n", setDevice(input.audioUnit, 0, in),
                       setDevice(engine.outputNode.audioUnit, 0, spk));
            }
            if (![input setVoiceProcessingEnabled:YES error:&err]) {
                printf("voice processing not enabled: %s\n", err.localizedDescription.UTF8String);
                continue;
            }
            AudioUnit unit = input.audioUnit;
            if ([pick isEqualToString:@"after"]) {
                printf("picking the input: %d, the output: %d\n", setDevice(unit, 1, in),
                       setDevice(engine.outputNode.audioUnit, 0, spk));
            } else if ([pick isEqualToString:@"input"]) {
                printf("picking the input: %d\n", setDevice(unit, 1, in));
            }
            for (UInt32 element : {0u, 1u}) {
                AudioDeviceID id = kAudioObjectUnknown;
                UInt32 size = sizeof(id);
                OSStatus s = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, element, &id, &size);
                printf("the unit's device, element %u: %s (%d)\n", element, deviceName(id).c_str(),
                       (int)s);
            }

            Recording vp;
            Recording* vpRec = &vp;
            AVAudioFormat* tapFormat = [input outputFormatForBus:0];
            vp.rate = tapFormat.sampleRate;
            printf("voice-processed input: %.0f Hz, %u channel(s)\n", tapFormat.sampleRate,
                   (unsigned)tapFormat.channelCount);
            [input installTapOnBus:0
                        bufferSize:2048
                            format:tapFormat
                             block:^(AVAudioPCMBuffer* buf, AVAudioTime*) {
                               vpRec->add(buf.floatChannelData[0], buf.frameLength);
                             }];
            AVAudioPlayerNode* player = [AVAudioPlayerNode new];
            [engine attachNode:player];
            [engine connect:player to:engine.mainMixerNode format:speechBuffer.format];
            [engine prepare];
            if (![engine startAndReturnError:&err]) {
                printf("the engine didn't start: %s\n", err.localizedDescription.UTF8String);
                [input removeTapOnBus:0];
                continue;
            }
            wait(1.5);
            printf("devices with voice processing running:\n");
            listDevices();

            // The same input without processing, alongside.
            PlainInput plain;
            if (!plain.start(in)) return 1;
            wait(1.5);

            // Plays the voice for `seconds` after a second of room; leaves out its first two
            // seconds, while the canceller adapts.
            std::vector<Step> steps;
            auto measure = [&](const char* what, void (^startVoice)(void), void (^stopVoice)(void)) {
                size_t v0 = vp.now(), p0 = plain.rec.now();
                wait(1);
                Step s = {what, vp.db(v0, vp.now()), 0, plain.rec.db(p0, plain.rec.now()), 0};
                startVoice();
                wait(2);
                size_t v1 = vp.now(), p1 = plain.rec.now();
                wait(seconds - 2);
                s.vpVoice = vp.db(v1, vp.now());
                s.plainVoice = plain.rec.db(p1, plain.rec.now());
                stopVoice();
                steps.push_back(s);
                wait(0.5);
            };
            measure(
                "its own output",
                ^{
                  [player scheduleBuffer:speechBuffer atTime:nil options:AVAudioPlayerNodeBufferLoops
                       completionHandler:nil];
                  [player play];
                },
                ^{ [player stop]; });
            measure("another output", ^{ o->start(speakerID, *voice); }, ^{ o->stop(); });
            __block pid_t child = 0;
            measure(
                "another process",
                ^{
                  const char* args[] = {exe.c_str(), "--play", speakerName.c_str(), "--speech",
                                        speechPath.c_str(), "--seconds", secs.c_str(), nullptr};
                  posix_spawn(&child, exe.c_str(), nullptr, nullptr, (char**)args, environ);
                },
                ^{
                  int status;
                  waitpid(child, &status, 0);
                });
            // macOS 14's setting for how much the other audio is lowered.
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration least = {
                .enableAdvancedDucking = NO,
                .duckingLevel = AVAudioVoiceProcessingOtherAudioDuckingLevelMin};
            input.voiceProcessingOtherAudioDuckingConfiguration = least;
            measure("another output, least ducking", ^{ o->start(speakerID, *voice); },
                    ^{ o->stop(); });
            input.voiceProcessingBypassed = YES;
            measure("another output, processing bypassed", ^{ o->start(speakerID, *voice); },
                    ^{ o->stop(); });

            plain.stop();
            [engine stop];
            [input removeTapOnBus:0];

            // The voice over the room in each input, the difference between the two, and how
            // much quieter the plain input heard it than without voice processing.
            printf("%-40s %9s %9s %9s %9s\n", "the voice (dB over the room)", "processed", "plain",
                   "taken out", "ducked");
            for (const Step& s : steps) {
                double v = over(s.vpVoice, s.vpRoom), p = over(s.plainVoice, s.plainRoom);
                printf("%-40s %9.1f %9.1f %9.1f %9.1f\n", s.what, v, p, p - v, unprocessed - p);
            }
            printf("room (dBFS, processed/plain): ");
            for (const Step& s : steps) printf("%.1f/%.1f  ", s.vpRoom, s.plainRoom);
            printf("\n");
            wait(1);
        }
    }
    return 0;
}
