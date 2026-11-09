import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = AudioManager()
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { mixer.shutdown() }
}

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Volume Mixer", id: "mixer") {
            ContentView(audioManager: delegate.mixer)
        }
        .defaultSize(width: 540, height: 420)
    }
}
