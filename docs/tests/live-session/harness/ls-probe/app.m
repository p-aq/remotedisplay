// ls-probe's "app" (run.sh): an accessory app that notes each launch in LOGPATH, then stays up.
#import <AppKit/AppKit.h>
int main(int argc, char** argv) { @autoreleasepool {
    NSString* log = @LOGPATH;
    FILE* f = fopen(log.UTF8String, "a"); fprintf(f, "app launched pid %d\n", getpid()); fclose(f);
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; [NSApp run];
}}
