import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utilities don't get a Dock icon or app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct AirMouseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = ServerManager()

    var body: some Scene {
        MenuBarExtra("Air Mouse", systemImage: "cursorarrow.rays") {
            ContentView(server: server)
        }
        .menuBarExtraStyle(.window)
    }
}
