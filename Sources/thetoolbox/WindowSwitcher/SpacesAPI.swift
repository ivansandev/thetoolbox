import CoreGraphics
import Foundation

/// Private SkyLight calls for desktops (spaces). Every method returns nil or empty when macOS no
/// longer provides a call; the window list then treats every window as on the current desktop.
final class SpacesAPI {
    static let shared = SpacesAPI()

    struct Desktops {
        /// The current desktop of every display.
        let current: Set<UInt64>
        /// Desktops that hold a fullscreen app.
        let fullscreen: Set<UInt64>

        /// True when a display is showing a fullscreen app's desktop.
        var currentIsFullscreen: Bool { !current.isDisjoint(with: fullscreen) }
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let mainConnectionID = PrivateSymbols.function("SLSMainConnectionID", as: MainConnectionID.self)
        ?? PrivateSymbols.function("CGSMainConnectionID", as: MainConnectionID.self)
    private let copyManagedDisplaySpaces = PrivateSymbols.function("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        ?? PrivateSymbols.function("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private let copySpacesForWindows = PrivateSymbols.function("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
        ?? PrivateSymbols.function("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)

    /// Selector for "all spaces" in CGSCopySpacesForWindows.
    private static let allSpacesMask: Int32 = 7
    /// Space type of a fullscreen app's desktop in CGSCopyManagedDisplaySpaces.
    private static let fullscreenSpaceType = 4

    private init() {}

    func desktops() -> Desktops? {
        guard let mainConnectionID, let copyManagedDisplaySpaces,
              let array = copyManagedDisplaySpaces(mainConnectionID())?.takeRetainedValue(),
              let displays = (array as NSArray) as? [[String: Any]] else { return nil }
        var current = Set<UInt64>()
        var fullscreen = Set<UInt64>()
        for display in displays {
            if let space = display["Current Space"] as? [String: Any], let id = Self.id(of: space) {
                current.insert(id)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? []
            where (space["type"] as? NSNumber)?.intValue == Self.fullscreenSpaceType {
                if let id = Self.id(of: space) { fullscreen.insert(id) }
            }
        }
        return current.isEmpty ? nil : Desktops(current: current, fullscreen: fullscreen)
    }

    /// The desktops `windowID` is on; empty when unknown.
    func spaceIDs(of windowID: CGWindowID) -> Set<UInt64> {
        guard let mainConnectionID, let copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: windowID)] as CFArray
        guard let array = copySpacesForWindows(mainConnectionID(), Self.allSpacesMask, ids)?.takeRetainedValue(),
              let spaces = (array as NSArray) as? [NSNumber] else { return [] }
        return Set(spaces.map(\.uint64Value))
    }

    private static func id(of space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber ?? space["id64"] as? NSNumber)?.uint64Value
    }
}
