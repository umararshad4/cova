// ColorSync is where CGDisplayCreateUUIDFromDisplayID lives — public API, awkward home.
import ColorSync
import CoreGraphics
import Foundation

/// Runtime lookup for Apple's private frameworks.
///
/// Deliberately `dlopen`/`dlsym` rather than linking: a missing or renamed symbol on a future macOS
/// degrades one feature instead of refusing to launch the app. Every caller must handle `nil`.
enum Private {
    private static func open(_ path: String) -> UnsafeMutableRawPointer? {
        dlopen(path, RTLD_LAZY)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // MARK: - DisplayServices (display brightness)

    private static let displayServices = open(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    )

    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    static let displayServicesGetBrightness =
        symbol(displayServices, "DisplayServicesGetBrightness", as: GetBrightness.self)
    static let displayServicesSetBrightness =
        symbol(displayServices, "DisplayServicesSetBrightness", as: SetBrightness.self)
    static let displayServicesCanChangeBrightness =
        symbol(displayServices, "DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)

    // MARK: - CoreBrightness (keyboard backlight)

    private static let coreBrightness = open(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    )

    /// `KeyboardBrightnessClient` is Objective-C, so it comes through the runtime rather than dlsym.
    static var keyboardBrightnessClient: AnyObject? = {
        _ = coreBrightness
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static func keyboardBrightness(forDisplay display: UInt32 = 1) -> Float? {
        guard let client = keyboardBrightnessClient else { return nil }
        let selector = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: selector) else { return nil }
        // The selector returns a float; use an IMP cast so the value survives.
        typealias Fn = @convention(c) (AnyObject, Selector, UInt64) -> Float
        guard let method = class_getInstanceMethod(type(of: client), selector) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        return imp(client, selector, UInt64(display))
    }

    // MARK: - SkyLight / CoreGraphics Services (lock screen spaces)

    private static let skyLight = open(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    )

    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    /// `SLSSpaceCreate(cid, 1, 0)`. The second argument really is the literal 1 — passing nil
    /// returns 0 on every macOS tested, which is the bug that made lock-screen widgets silently
    /// never appear.
    typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void
    typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    /// `SLSSpaceAddWindowsAndRemoveFromSpaces(cid, space, windows, 7)`
    typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void
    typealias ShowHideSpaces = @convention(c) (Int32, CFArray) -> Void

    static let cgsMainConnectionID =
        symbol(skyLight, "SLSMainConnectionID", as: MainConnectionID.self)
        ?? symbol(skyLight, "CGSMainConnectionID", as: MainConnectionID.self)
    private static let cgsCopyManagedDisplaySpaces =
        symbol(skyLight, "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        ?? symbol(skyLight, "CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    static let cgsSpaceCreate =
        symbol(skyLight, "SLSSpaceCreate", as: SpaceCreate.self)
        ?? symbol(skyLight, "CGSSpaceCreate", as: SpaceCreate.self)
    static let cgsSpaceDestroy =
        symbol(skyLight, "SLSSpaceDestroy", as: SpaceDestroy.self)
        ?? symbol(skyLight, "CGSSpaceDestroy", as: SpaceDestroy.self)
    static let cgsSpaceSetAbsoluteLevel =
        symbol(skyLight, "SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self)
        ?? symbol(skyLight, "CGSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self)
    static let cgsSpaceAddWindows =
        symbol(skyLight, "SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindows.self)

    /// Absolute level that renders above the login window.
    /// `kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock`.
    static let lockScreenSpaceLevel: Int32 = 400
    static let cgsShowSpaces =
        symbol(skyLight, "SLSShowSpaces", as: ShowHideSpaces.self)
        ?? symbol(skyLight, "CGSShowSpaces", as: ShowHideSpaces.self)
    static let cgsHideSpaces =
        symbol(skyLight, "SLSHideSpaces", as: ShowHideSpaces.self)
        ?? symbol(skyLight, "CGSHideSpaces", as: ShowHideSpaces.self)

    /// `SLSCopyManagedDisplaySpaces` returns one entry per managed display. Asking "does ANY display
    /// have a fullscreen Space" hid the island on the built-in notch whenever a video went
    /// fullscreen on a second monitor — with `hideWhileInFullscreen` on by default, dual-monitor
    /// users simply lost the island during normal work.
    ///
    /// `matching` is the display's UUID string. Some macOS versions report the main display's entry
    /// as the literal "Main" rather than a UUID, so that is accepted too. An unrecognised layout
    /// falls back to the old any-display answer rather than silently reporting "not fullscreen".
    static func hasActiveFullScreenSpace(_ displays: [[String: Any]], matching uuid: String? = nil) -> Bool {
        func isFullScreen(_ display: [String: Any]) -> Bool {
            guard let current = display["Current Space"] as? [String: Any] else { return false }
            return current["type"] as? Int == 4
        }

        guard let uuid else { return displays.contains(where: isFullScreen) }

        let scoped = displays.filter { display in
            guard let identifier = display["Display Identifier"] as? String else { return false }
            return identifier == uuid || identifier == "Main"
        }
        guard !scoped.isEmpty else { return displays.contains(where: isFullScreen) }
        return scoped.contains(where: isFullScreen)
    }

    /// UUID string for a display, as `SLSCopyManagedDisplaySpaces` spells it.
    static func displayUUID(for display: CGDirectDisplayID) -> String? {
        guard display != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(display) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    /// Native fullscreen windows live in a dedicated Space even when the user's menu bar setting
    /// leaves `currentSystemPresentationOptions` at `.default`. This uses the same optional
    /// SkyLight lookup as the lock-screen feature and falls back cleanly if Apple removes it.
    static func activeSpaceIsFullScreen(onDisplay display: CGDirectDisplayID = 0) -> Bool? {
        guard let mainConnection = cgsMainConnectionID,
              let copySpaces = cgsCopyManagedDisplaySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return hasActiveFullScreenSpace(displays, matching: displayUUID(for: display))
    }

    // MARK: - Screen capture detection

    /// `bool CGSIsScreenWatcherPresent(void)` — true when something is capturing the display.
    /// There is no public equivalent; this is the only way to mirror macOS's own recording
    /// indicator. Absent symbol simply disables the feature.
    typealias IsScreenWatcherPresent = @convention(c) () -> Bool

    static let cgsIsScreenWatcherPresent =
        symbol(skyLight, "SLSIsScreenWatcherPresent", as: IsScreenWatcherPresent.self)
        ?? symbol(skyLight, "CGSIsScreenWatcherPresent", as: IsScreenWatcherPresent.self)

    static var screenIsBeingWatched: Bool {
        cgsIsScreenWatcherPresent?() ?? false
    }

    /// True when the login window is up. Public API, no dlsym needed.
    static var screenIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
