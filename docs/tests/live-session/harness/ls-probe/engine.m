// ls-probe's "engine" (run.sh): headless, Prohibited, running NSApp like remotedisplayd's
// MacRunHeadlessAppLoop, and asking for Screen Recording's status so tccd logs which
// identity it checks. With --forward it answers open/reopen by starting the bundle's app
// and ignores quit, after AppKit's launch (which installs its own handlers over earlier ones).
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
static NSString* Log(void) { return @LOGPATH; }
static void Note(NSString* s) { FILE* f = fopen(Log().UTF8String, "a"); fprintf(f, "engine %d: %s\n", getpid(), s.UTF8String); fclose(f); }
@interface H : NSObject @end
@implementation H
- (void)open:(NSAppleEventDescriptor*)e reply:(NSAppleEventDescriptor*)r {
    Note([NSString stringWithFormat:@"got '%@', starting the app", NSFileTypeForHFSTypeCode(e.eventID)]);
    NSWorkspaceOpenConfiguration* c = [NSWorkspaceOpenConfiguration configuration];
    c.createsNewApplicationInstance = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:[[NSBundle mainBundle] bundleURL] configuration:c completionHandler:^(NSRunningApplication* a, NSError* err) {
        Note(err ? [NSString stringWithFormat:@"start failed: %@", err] : [NSString stringWithFormat:@"started pid %d", a.processIdentifier]); }];
}
- (void)quit:(NSAppleEventDescriptor*)e reply:(NSAppleEventDescriptor*)r { Note(@"got 'quit', ignored"); }
@end
int main(int argc, char** argv) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    static H* h; h = [H new];
    BOOL forward = argc > 1 && !strcmp(argv[1], "--forward");
    // After AppKit's own launch, which installs its handlers over any set before.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (forward) {
            NSAppleEventManager* m = [NSAppleEventManager sharedAppleEventManager];
            [m setEventHandler:h andSelector:@selector(open:reply:) forEventClass:kCoreEventClass andEventID:kAEOpenApplication];
            [m setEventHandler:h andSelector:@selector(open:reply:) forEventClass:kCoreEventClass andEventID:kAEReopenApplication];
            [m setEventHandler:h andSelector:@selector(quit:reply:) forEventClass:kCoreEventClass andEventID:kAEQuitApplication];
        }
        Note([NSString stringWithFormat:@"started%@; screen recording preflight %d", forward ? @" with --forward" : @"", CGPreflightScreenCaptureAccess()]);
    });
    [NSApp run];
}}
