// Remote Display live-session test (../README.md, decision 0033): starts Remote Display
// Camera's sink stream the way remotedisplayd does, then stops it after 0.3 s, or after the
// seconds given (`./p1 30`), sending no frames. The extension logs whether it accepted this
// process as a feeder, and why not. Held for a while, it shows whether the extension keeps
// the sink for one feeder at a time and whether the app names it (decision 0033, option 2).
// Build it several ways to see what the extension makes of each (decision 0033):
//
//   cc() { xcrun clang -fobjc-arc -framework CoreMediaIO -framework CoreMedia -framework Foundation "$@"; }
//   cc sink_probe.m -o p1 && codesign -s - -f --identifier app.remotedisplay.probe p1        # ad-hoc
//   cc sink_probe.m -o p2 && codesign -s "$SIGN_ID" -f -o runtime --identifier app.remotedisplay.probe p2
//   cc sink_probe.m -o p5 && codesign -s - -f --identifier app.remotedisplay.server p5       # a spoof
//   ./p1; ./p2; ./p5
//   /usr/bin/log show --last 1m --predicate 'subsystem == "app.remotedisplay.server.camera"'
#import <CoreMediaIO/CMIOHardware.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static NSString* Name(CMIOObjectID o) {
    CMIOObjectPropertyAddress a = {kCMIOObjectPropertyName, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    CFStringRef s = NULL; UInt32 used = 0;
    if (CMIOObjectGetPropertyData(o, &a, 0, NULL, sizeof(s), &used, &s) != 0 || !s) return @"";
    return CFBridgingRelease(s);
}
static void Altered(CMIOStreamID s, void* t, void* r) {}
int main(int argc, char** argv) {
    @autoreleasepool {
        CMIOObjectPropertyAddress a = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        UInt32 size = 0, used = 0;
        CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &a, 0, NULL, &size);
        CMIOObjectID ids[64]; if (size > sizeof(ids)) size = sizeof(ids);
        CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &a, 0, NULL, size, &used, ids);
        for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) {
            if (![Name(ids[i]) isEqualToString:@"Remote Display Camera"]) continue;
            CMIOObjectPropertyAddress sa = {kCMIODevicePropertyStreams, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
            UInt32 ss = 0, su = 0; CMIOObjectID st[8];
            CMIOObjectGetPropertyDataSize(ids[i], &sa, 0, NULL, &ss); if (ss > sizeof(st)) ss = sizeof(st);
            CMIOObjectGetPropertyData(ids[i], &sa, 0, NULL, ss, &su, st);
            for (UInt32 j = 0; j < su / sizeof(CMIOObjectID); j++) {
                if (![Name(st[j]) hasSuffix:@" Sink"]) continue;
                CMSimpleQueueRef q = NULL;
                OSStatus e = CMIOStreamCopyBufferQueue(st[j], Altered, NULL, &q);
                OSStatus s = e ? e : CMIODeviceStartStream(ids[i], st[j]);
                printf("pid %d: start sink -> %d\n", getpid(), (int)s);
                if (!s) {
                    double hold = argc > 1 ? atof(argv[1]) : 0.3;
                    usleep((useconds_t)(hold * 1e6));
                    CMIODeviceStopStream(ids[i], st[j]);
                }
                if (q) CFRelease(q);
                return s ? 1 : 0;
            }
        }
        printf("pid %d: no sink found\n", getpid());
        return 2;
    }
}
