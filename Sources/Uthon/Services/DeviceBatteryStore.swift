import Foundation
import IOKit
import IOKit.ps
import IOBluetooth
import CoreBluetooth

/// Battery levels of Magic Mouse / Keyboard / Trackpad, headphones on connect,
/// and the Mac's own battery (MacBook only: iMacs have none, so nothing shows there).
final class DeviceBatteryStore: ObservableObject {
    static let shared = DeviceBatteryStore()

    struct Device: Identifiable, Equatable {
        var name: String
        let percent: Int
        /// Bluetooth address, normalised ("10:cf:0f:e5:d4:da"), when known.
        var address: String? = nil
        /// True when the name is only a guess ("Keyboard") because macOS did not give one.
        var nameIsGuess = false
        /// Plugged in to charge (cable or power), when a source tells us.
        var charging = false
        var id: String { address ?? name }
        var symbol: String { DeviceBatteryStore.symbol(for: name) }
    }

    /// "10-CF-0F-E5-D4-DA" / "10:cf:0f:e5:d4:da" -> "10:cf:0f:e5:d4:da"
    static func normalizeAddress(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = text.lowercased().replacingOccurrences(of: "-", with: ":").trimmingCharacters(in: .whitespaces)
        return looksLikeAddress(cleaned) ? cleaned : nil
    }

    static func looksLikeAddress(_ text: String) -> Bool {
        text.range(of: "^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$", options: .regularExpression) != nil
    }

    @Published private(set) var devices: [Device] = []
    /// What each source found the last time we looked (shown in Settings → Widgets).
    @Published private(set) var report: [String] = []
    @Published private(set) var lastChecked: Date?
    /// True only on Macs with a built-in battery (MacBooks).
    @Published private(set) var hasInternalBattery = false
    /// Looking right now (Settings shows a spinner).
    @Published private(set) var looking = false
    /// Connected devices that have not reported a battery level (yet).
    @Published private(set) var connectedWithoutLevel: [String] = []

    private let watcher = DeviceConnectionWatcher()
    private var followUps: [DispatchWorkItem] = []

    private var warned: Set<String> = []
    private var deviceTimer: Timer?
    private var powerTimer: Timer?
    private var lastCharging: Bool?

    /// Every 5 minutes; every minute while something charges (so the level climbs visibly).
    private func scheduleDeviceTimer() {
        let interval: TimeInterval = devices.contains { $0.charging } ? 60 : 300
        guard deviceTimer?.timeInterval != interval else { return }
        deviceTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refreshDevices() }
        RunLoop.main.add(t, forMode: .common)
        deviceTimer = t
    }

    func start() {
        refreshDevices()
        // A mouse or keyboard that connects (or wakes up) is picked up at once, not at the next
        // five-minute check. Its battery level appears a moment after it connects, so look a
        // few times.
        watcher.start { [weak self] in self?.deviceConnectionChanged() }
        scheduleDeviceTimer()

        // Charging animation: only if this Mac has a battery.
        if let battery = Self.internalBattery() {
            hasInternalBattery = true
            lastCharging = battery.pluggedIn
            let p = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkPower() }
            RunLoop.main.add(p, forMode: .common)
            powerTimer = p
        }
    }

    // MARK: MacBook charging

    private func checkPower() {
        guard let battery = Self.internalBattery() else { return }
        defer { lastCharging = battery.pluggedIn }
        if let last = lastCharging, !last, battery.pluggedIn, AppSettings.shared.peekCharging {
            IslandController.shared.showPeek(.charging(percent: battery.percent), duration: 3.5)
        }
    }

    static func internalBattery() -> (percent: Int, charging: Bool, pluggedIn: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (current * 100 / max, charging, pluggedIn)
        }
        return nil
    }

    // MARK: Magic Mouse / Keyboard / Trackpad

    func deviceConnectionChanged() {
        followUps.forEach { $0.cancel() }
        followUps = [2.0, 8.0, 25.0].map { delay in
            let work = DispatchWorkItem { [weak self] in self?.refreshDevices() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private var inFlight = false

    func refreshDevices() {
        guard !inFlight else { return }
        inFlight = true
        if !looking { looking = true }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lines: [String] = []
            let found = Self.readDevices(report: &lines)
            let connected = Self.connectedNames()
            let withoutLevel = connected.filter { name in !found.contains { Self.sameDevice($0.name, name) } }
            if !withoutLevel.isEmpty { lines.append("Connected, no battery level yet: " + withoutLevel.joined(separator: ", ")) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                if self.devices != found { self.devices = found }
                self.report = lines
                if self.connectedWithoutLevel != withoutLevel { self.connectedWithoutLevel = withoutLevel }
                self.lastChecked = Date()
                self.looking = false
                self.checkLow()
                self.scheduleDeviceTimer()
            }
        }
    }

    /// Names of connected Bluetooth devices, whether or not they report a battery.
    static func connectedNames() -> [String] {
        guard CBManager.authorization == .allowedAlways else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.filter { $0.isConnected() }.compactMap { device in
            let name = (device.name ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !looksLikeAddress(name) else { return nil }
            // Only things that could have a battery we show (keyboards, mice, trackpads, audio).
            return (device.deviceClassMajor == 0x05 || device.deviceClassMajor == 0x04) ? name : nil
        }
    }

    private func checkLow() {
        for device in devices {
            if device.percent <= 15, !device.charging, !warned.contains(device.name) {
                warned.insert(device.name)
                IslandController.shared.showPeek(.lowBattery(name: device.name, percent: device.percent), duration: 6)
            } else if device.percent > 30 {
                warned.remove(device.name)
            }
        }
    }

    /// Wireless devices with a battery. macOS keeps this in different places depending on
    /// the version and the device, so every known place is asked and the results merged.
    static func readDevices() -> [Device] {
        var ignored: [String] = []
        return readDevices(report: &ignored)
    }

    static func readDevices(report: inout [String]) -> [Device] {
        var result: [Device] = []
        func merge(_ found: [Device], source: String) {
            report.append("\(source): " + (found.isEmpty ? "nothing" : found.map {
                "\($0.name)\($0.address.map { " [\($0)]" } ?? "") \($0.percent)%\($0.charging ? " charging" : "")"
            }.joined(separator: ", ")))
            for device in found {
                if let index = result.firstIndex(where: { existing in
                    (existing.address != nil && existing.address == device.address) || sameDevice(existing.name, device.name)
                }) {
                    // Same device: keep the level from the more live source (they are asked in
                    // that order), take a real name over a guess, and note charging from any source.
                    if result[index].nameIsGuess && !device.nameIsGuess { result[index].name = device.name; result[index].nameIsGuess = false }
                    if result[index].address == nil { result[index].address = device.address }
                    if device.charging { result[index].charging = true }
                } else {
                    result.append(device)
                }
            }
        }
        // Live sources first: the device registry is updated by the device itself (also while it
        // charges over a cable); Bluetooth's own figure can be an old, cached one.
        merge(hidServices(), source: "HID registry")
        merge(parseRegistry(run("/usr/sbin/ioreg", ["-r", "-l", "-a", "-k", "BatteryPercent"])), source: "ioreg")
        merge(powerSourceAccessories(), source: "Power sources")
        merge(bluetoothDevices(), source: "Bluetooth")
        merge(parseBluetooth(run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])), source: "System Information")
        // Last chance for a real name: System Information lists every paired device by address.
        let names = bluetoothNames(run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]))
        for index in result.indices where result[index].nameIsGuess {
            if let address = result[index].address, let name = names[address] {
                result[index].name = name
                result[index].nameIsGuess = false
            }
        }
        return result.sorted { order($0.name) < order($1.name) }
    }

    static func sameDevice(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Paired Bluetooth devices that are connected. The battery level comes from the same
    /// (non-public) properties System Settings uses; checked with responds(to:) so it can never crash.
    static func bluetoothDevices() -> [Device] {
        // Only ask once the user allowed Bluetooth (the Batteries widget asks for it).
        guard CBManager.authorization == .allowedAlways else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        var result: [Device] = []
        for device in paired where device.isConnected() {
            let address = normalizeAddress(device.addressString)
            let rawName = (device.name ?? "").trimmingCharacters(in: .whitespaces)
            let hasName = !rawName.isEmpty && !looksLikeAddress(rawName)
            let name = hasName ? rawName : guessName(major: device.deviceClassMajor, minor: device.deviceClassMinor)
            var levels: [Int] = []
            for key in ["batteryPercentSingle", "batteryPercentLeft", "batteryPercentRight", "batteryPercentCombined"] {
                guard device.responds(to: NSSelectorFromString(key)),
                      let value = (device.value(forKey: key) as? NSNumber)?.intValue, value > 0, value <= 100 else { continue }
                levels.append(value)
            }
            if let level = levels.min() {
                result.append(Device(name: name, percent: level, address: address, nameIsGuess: !hasName))
            }
        }
        return result
    }

    /// A readable name from the Bluetooth device class when macOS gives none.
    static func guessName(major: UInt32, minor: UInt32) -> String {
        // Major class 0x05 = peripheral; minor bits 0x10 keyboard, 0x20 pointing device.
        if major == 0x05 {
            if minor & 0x10 != 0 && minor & 0x20 != 0 { return "Keyboard & Mouse" }
            if minor & 0x10 != 0 { return "Keyboard" }
            if minor & 0x20 != 0 { return "Mouse" }
        }
        if major == 0x04 { return "Headphones" }   // audio/video
        return "Bluetooth device"
    }

    /// Bluetooth needs the user's OK once; the Batteries widget asks for it.
    static func requestBluetoothAccess() {
        guard CBManager.authorization == .notDetermined else { return }
        // Creating a central manager shows the system prompt.
        bluetoothPrompt = CBCentralManager(delegate: nil, queue: nil)
    }

    private static var bluetoothPrompt: CBCentralManager?

    /// The classic place: AppleDeviceManagementHIDEventService entries in the I/O registry.
    static func hidServices() -> [Device] {
        var result: [Device] = []
        for className in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                let percent = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BatteryPercent" as CFString, kCFAllocatorDefault, options)
                    as? NSNumber
                let name = (IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Product" as CFString, kCFAllocatorDefault, options) as? String)
                guard let value = percent?.intValue, (1...100).contains(value), let name, !name.isEmpty,
                      !result.contains(where: { sameDevice($0.name, name) }) else { continue }
                let address = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "DeviceAddress" as CFString, kCFAllocatorDefault, options) as? String
                let transport = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Transport" as CFString, kCFAllocatorDefault, options) as? String
                let flags = (IORegistryEntrySearchCFProperty(service, kIOServicePlane, "BatteryStatusFlags" as CFString, kCFAllocatorDefault, options) as? NSNumber)?.intValue
                result.append(Device(name: name, percent: value, address: normalizeAddress(address), nameIsGuess: looksLikeAddress(name),
                                     charging: isCharging(transport: transport, flags: flags)))
            }
        }
        return result
    }

    /// Magic devices report charging with a status flag, and use USB while a cable is in.
    static func isCharging(transport: String?, flags: Int?) -> Bool {
        if let transport, transport.uppercased().contains("USB") { return true }
        if let flags, flags == 3 { return true }
        return false
    }

    /// Some macOS versions also list accessories (AirPods, Magic devices) as power sources.
    static func powerSourceAccessories() -> [Device] {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        var result: [Device] = []
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (info[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType,
                  let name = info[kIOPSNameKey] as? String, !name.isEmpty,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (info[kIOPSIsChargingKey] as? Bool ?? false) || (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            result.append(Device(name: name, percent: current * 100 / max, charging: charging))
        }
        return result
    }

    private static func order(_ name: String) -> Int {
        let n = name.lowercased()
        if n.contains("keyboard") { return 0 }
        if n.contains("mouse") { return 1 }
        if n.contains("trackpad") { return 2 }
        return 3
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// `ioreg -r -l -a -k BatteryPercent` output: a plist array of registry entries (with children).
    static func parseRegistry(_ data: Data) -> [Device] {
        guard !data.isEmpty,
              let list = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]] else { return [] }
        var result: [Device] = []
        func visit(_ entry: [String: Any], inheritedName: String?, inheritedTransport: String? = nil) {
            let ioClass = entry["IOClass"] as? String ?? ""
            let ownName = ((entry["Product"] as? String) ?? (entry["DeviceName"] as? String))?.trimmingCharacters(in: .whitespaces)
            let name = (ownName?.isEmpty == false ? ownName : nil) ?? inheritedName
            if !ioClass.contains("AppleSmartBattery"),
               let percent = (entry["BatteryPercent"] as? NSNumber)?.intValue, (1...100).contains(percent),
               let name, !name.isEmpty, !result.contains(where: { sameDevice($0.name, name) }) {
                let address = normalizeAddress(entry["DeviceAddress"] as? String) ?? normalizeAddress(entry["SerialNumber"] as? String)
                let charging = isCharging(transport: entry["Transport"] as? String ?? inheritedTransport,
                                          flags: (entry["BatteryStatusFlags"] as? NSNumber)?.intValue)
                result.append(Device(name: name, percent: percent, address: address, nameIsGuess: looksLikeAddress(name), charging: charging))
            }
            for child in entry["IORegistryEntryChildren"] as? [[String: Any]] ?? [] {
                visit(child, inheritedName: name, inheritedTransport: entry["Transport"] as? String ?? inheritedTransport)
            }
        }
        for entry in list { visit(entry, inheritedName: nil) }
        return result
    }

    /// Every paired device's name by address, from `system_profiler SPBluetoothDataType -json`.
    static func bluetoothNames(_ data: Data) -> [String: String] {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var names: [String: String] = [:]
        func visit(_ object: Any) {
            if let dict = object as? [String: Any] {
                for (key, value) in dict {
                    if let info = value as? [String: Any], let address = normalizeAddress(info["device_address"] as? String),
                       !looksLikeAddress(key) {
                        names[address] = key
                    }
                    visit(value)
                }
            } else if let array = object as? [Any] {
                array.forEach(visit)
            }
        }
        visit(json)
        return names
    }

    /// `system_profiler SPBluetoothDataType -json`: connected devices that report a battery level.
    static func parseBluetooth(_ data: Data) -> [Device] {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var result: [Device] = []
        func percent(_ value: Any?) -> Int? {
            guard let text = value as? String else { return nil }
            return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        func visit(_ object: Any, connected: Bool) {
            if let dict = object as? [String: Any] {
                for (key, value) in dict {
                    let isConnectedList = key == "device_connected"
                    if connected, let info = value as? [String: Any] {
                        let levels = [percent(info["device_batteryLevelMain"]),
                                      percent(info["device_batteryLevelLeft"]),
                                      percent(info["device_batteryLevelRight"])].compactMap { $0 }
                        if let level = levels.min(), !result.contains(where: { $0.name == key }) {
                            result.append(Device(name: key, percent: level,
                                                 address: normalizeAddress(info["device_address"] as? String),
                                                 nameIsGuess: looksLikeAddress(key)))
                            continue
                        }
                    }
                    visit(value, connected: connected || isConnectedList)
                }
            } else if let array = object as? [Any] {
                for value in array { visit(value, connected: connected) }
            }
        }
        visit(json, connected: false)
        return result
    }

    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("mouse") { return "magicmouse.fill" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if n.contains("keyboard") { return "keyboard.fill" }
        if n.contains("airpods") || n.contains("beats") || n.contains("headphone") || n.contains("buds") {
            return headphoneSymbol(for: name)
        }
        if n.contains("controller") || n.contains("gamepad") { return "gamecontroller.fill" }
        if n.contains("pencil") { return "applepencil" }
        return "battery.75percent"
    }

    /// Short label for tight spaces: "Magic Keyboard with Touch ID" -> "Keyboard".
    static func shortName(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("keyboard") { return "Keyboard" }
        if n.contains("mouse") { return "Mouse" }
        if n.contains("trackpad") { return "Trackpad" }
        if n.contains("airpods") { return "AirPods" }
        return name
    }

    // MARK: Headphones

    static func headphoneSymbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        return "headphones"
    }

    func headphonesConnected(name: String) {
        guard AppSettings.shared.peekHeadphones else { return }
        let symbol = Self.headphoneSymbol(for: name)
        IslandController.shared.showPeek(.headphones(name: name, symbol: symbol, levels: nil), duration: 5)
        DispatchQueue.global(qos: .utility).async {
            let levels = Self.bluetoothBattery(for: name)
            DispatchQueue.main.async {
                guard let levels else { return }
                IslandController.shared.updatePeek(.headphones(name: name, symbol: symbol, levels: levels))
            }
        }
    }

    /// Reads AirPods-style battery levels from System Information (takes about a second).
    private static func bluetoothBattery(for name: String) -> HeadphoneLevels? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var found: [String: Any]?
        func search(_ object: Any) {
            if found != nil { return }
            if let dict = object as? [String: Any] {
                if let info = dict[name] as? [String: Any] {
                    found = info
                    return
                }
                for value in dict.values { search(value) }
            } else if let array = object as? [Any] {
                for value in array { search(value) }
            }
        }
        search(json)
        guard let info = found else { return nil }

        func percent(_ key: String) -> Int? {
            guard let text = info[key] as? String else { return nil }
            return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }
        let levels = HeadphoneLevels(
            left: percent("device_batteryLevelLeft"),
            right: percent("device_batteryLevelRight"),
            caseLevel: percent("device_batteryLevelCase"),
            single: percent("device_batteryLevelMain")
        )
        return levels.isEmpty ? nil : levels
    }
}

struct HeadphoneLevels: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && single == nil }
}

/// Tells when a wireless keyboard, mouse or trackpad (or any Bluetooth device) connects or
/// goes away: from the I/O registry (where their battery level lives) and from Bluetooth.
final class DeviceConnectionWatcher: NSObject {
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var onChange: (() -> Void)?
    private var bluetoothConnect: IOBluetoothUserNotification?

    func start(_ onChange: @escaping () -> Void) {
        guard port == nil else { return }
        self.onChange = onChange
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            // Drain the iterator (required to keep receiving notifications).
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let refcon else { return }
            Unmanaged<DeviceConnectionWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }
        // Wireless devices appearing or leaving, and cables going in or out (a Magic Mouse or
        // keyboard on a cable becomes a USB device and starts charging).
        for className in ["AppleDeviceManagementHIDEventService", "IOUSBHostDevice"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                if IOServiceAddMatchingNotification(port, type, IOServiceMatching(className),
                                                    callback, context, &iterator) == KERN_SUCCESS {
                    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
                    iterators.append(iterator)
                }
            }
        }
        if CBManager.authorization == .allowedAlways {
            bluetoothConnect = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
        }
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        onChange?()
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        onChange?()
    }
}
