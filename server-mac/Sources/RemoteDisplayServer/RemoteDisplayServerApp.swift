import SwiftUI

@main
struct RemoteDisplayServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar = quick access for background use (status,
        // opening the configuration window, service, login item, quit).
        // All the configuration lives in the main window (MainWindowView).
        MenuBarExtra {
            StatusMenu()
                .environment(appDelegate.controller)
        } label: {
            let c = appDelegate.controller
            HStack(spacing: 2) {
                Image(systemName: c.isReady
                      ? "display"
                      : "display.trianglebadge.exclamationmark")
                // A camera or mic badge while a controller is sending (spec, What the user sees).
                if c.cameraSender != nil {
                    Image(systemName: "video.fill")
                }
                if c.microphoneSender != nil {
                    Image(systemName: "mic.fill")
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
