import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent. LSUIElement=YES in Info.plist hides the Dock icon
        // and the main menu, so there is nothing to set up here yet.
    }
}
