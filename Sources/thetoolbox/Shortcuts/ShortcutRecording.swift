import AppKit
import KeyboardShortcuts

enum ShortcutRecording {
    /// True while one of thetoolbox's KeyboardShortcuts recorders is listening. A focused
    /// recorder edits through the window's field editor, whose delegate is the recorder.
    /// Main thread only.
    static var isActive: Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.delegate is KeyboardShortcuts.RecorderCocoa
    }
}
