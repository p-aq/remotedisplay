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
            let symbol = c.isReady ? "display" : "display.trianglebadge.exclamationmark"
            // A camera or mic badge while a controller is sending (spec, What the user sees).
            let badges = (c.cameraSender == nil ? [] : ["video.fill"])
                + (c.microphoneSender == nil ? [] : ["mic.fill"])
            if badges.isEmpty {
                Image(systemName: symbol)
            } else {
                Image(nsImage: MenuBarIcon.badged(symbol, badges))
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
