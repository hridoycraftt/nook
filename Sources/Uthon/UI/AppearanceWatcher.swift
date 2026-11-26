import AppKit

/// Glass and materials keep the colors they were created with, so when macOS switches
/// between light and dark (by hand, from the Controls tab, or automatically at sunset)
/// every Uthon surface is rebuilt with the new look.
final class AppearanceWatcher {
    static let shared = AppearanceWatcher()

    private var observation: NSKeyValueObservation?
    private var lastIsDark: Bool?
    private var safetyTimer: Timer?

    /// The look decided at the last check, cached (cheap enough for views to read every frame).
    private(set) static var isDark = false

    func start() {
        lastIsDark = Self.systemIsDark
        Self.isDark = lastIsDark ?? false
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            // macOS applies the new look to windows a little after the notification, and not
            // always at once: look now and twice more, so nothing is left half-switched.
            self?.changed()
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.changed() }
            }
        }
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.changed() }
        }
        Self.applyToWindows()
        // A quiet check every minute, in case a switch (e.g. automatic at sunset) was missed.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.changed() }
        RunLoop.main.add(t, forMode: .common)
        safetyTimer = t
    }

    /// macOS's own Dark Mode setting, read straight from the system (the app's windows can
    /// lag behind it for a moment after a switch).
    static var macOSIsDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let auto = CFPreferencesCopyAppValue("AppleInterfaceStyleSwitchesAutomatically" as CFString,
                                             kCFPreferencesAnyApplication) as? Bool ?? false
        if auto {
            // "Auto" (light by day, dark at night): the system's own current look.
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let value = CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String
        return value?.lowercased() == "dark"
    }

    /// The look Nook should have now: the user's choice in Look, or macOS's own.
    static var systemIsDark: Bool {
        switch AppSettings.shared.appearance {
        case .light: return false
        case .dark: return true
        case .system: return macOSIsDark
        }
    }

    /// Every Nook window is given the look explicitly, so glass, materials and SwiftUI all
    /// switch together (the glass otherwise kept the old look while the cards changed).
    static func applyToWindows() {
        let look = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)
        // The app itself keeps following macOS when the choice is Auto (so the change signal
        // keeps coming); every window gets the look explicitly.
        let appLook = AppSettings.shared.appearance.nsAppearance
        if NSApp.appearance?.name != appLook?.name { NSApp.appearance = appLook }
        for window in NSApp.windows where window.appearance?.name != look?.name {
            window.appearance = look
        }
    }

    /// Called when the system look may have changed; rebuilds only if it really did.
    func changed(force: Bool = false) {
        let dark = Self.systemIsDark
        Self.isDark = dark
        Self.applyToWindows()
        guard force || dark != lastIsDark else { return }
        lastIsDark = dark
        AppSettings.shared.systemAppearanceTick += 1
        AppIcon.apply()
        QuickActions.shared.refresh()
    }
}

/// The app icon that matches the current appearance (dark icon in Dark Mode, light otherwise).
enum AppIcon {
    private static var loaded: [String: NSImage] = [:]

    /// Loaded from disk once per look, then kept (Settings redraws often).
    static var current: NSImage {
        let dark = AppearanceWatcher.systemIsDark
        let name = dark ? "AppIcon-Dark" : "AppIcon-Light"
        if let image = loaded[name] { return image }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            loaded[name] = image
            return image
        }
        return NSApp.applicationIconImage
    }

    /// Keep the Dock / app switcher icon in step with Light and Dark mode.
    static func apply() {
        guard Bundle.main.url(forResource: "AppIcon-Dark", withExtension: "png") != nil else { return }
        NSApp.applicationIconImage = current
    }
}
