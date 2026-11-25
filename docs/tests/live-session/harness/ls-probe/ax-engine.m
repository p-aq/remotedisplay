// ls-probe's Accessibility engine (accessibility.sh): headless like remotedisplayd, asking
// for Accessibility's and Screen Recording's status without a prompt, so tccd logs which
// identity it checks. Notes the answers in the file named by its argument, then exits.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
int main(int argc, char** argv) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    dispatch_async(dispatch_get_main_queue(), ^{
        FILE* f = fopen(argv[1], "a");
        fprintf(f, "%s: accessibility %d, screen %d\n", argv[0], AXIsProcessTrusted(), CGPreflightScreenCaptureAccess());
        fclose(f); exit(0);
    });
    [NSApp run];
}}
