/*
* ========================================================================== *
*                                                                            *
*    This file is part of the Openterface Mini KVM                           *
*                                                                            *
*    Copyright (C) 2024   <info@openterface.com>                             *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation version 3.                                 *
*                                                                            *
*    This program is distributed in the hope that it will be useful, but     *
*    WITHOUT ANY WARRANTY; without even the implied warranty of              *
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU        *
*    General Public License for more details.                                *
*                                                                            *
*    You should have received a copy of the GNU General Public License       *
*    along with this program. If not, see <http://www.gnu.org/licenses/>.    *
*                                                                            *
* ========================================================================== *
*/

import Foundation
import AppKit
import IOKit

private var logger: LoggerProtocol = DependencyContainer.shared.resolve(LoggerProtocol.self)

/// One physical Openterface unit (video chip + control chip + its serial port) that
/// this process could attach to. Only units with a video chip are listed.
struct OpenterfaceDeviceCandidate: Identifiable {
    /// Stable identifier: the video chip location ID.
    let id: String
    let index: Int
    let videoDevice: USBDeviceInfo
    let controlDevice: USBDeviceInfo?
    /// Callout path of the serial port that belongs to the control chip, resolved via IOKit.
    let serialPortPath: String?

    var videoLocationID: String? { videoDevice.locationID }
    var controlLocationID: String? { controlDevice?.locationID }
    var serialNumber: String? { videoDevice.serialNumber }

    /// Key used for cross-instance claims (same value `USBDevicesManager` claims).
    var unitKey: String { DeviceSelectionManager.unitKey(video: videoDevice, control: controlDevice) }

    /// Short hub/port identifier such as "0x1144".
    var shortLocation: String { DeviceSelectionManager.shortLocationID(videoDevice.locationID) }

    /// Label used in menus and pickers: nickname, else "Openterface <serial>", else location.
    var displayName: String {
        if let nickname = DeviceSelectionManager.shared.nickname(for: self), !nickname.isEmpty {
            return nickname
        }
        return defaultName
    }

    /// Name without the user nickname applied.
    var defaultName: String {
        let product = videoDevice.productName.contains("Unknown") ? "Openterface" : videoDevice.productName
        if let serial = serialNumber, !serial.isEmpty {
            return "\(product) \(serial)"
        }
        return "\(product) (\(shortLocation))"
    }

    /// Compact label appended to the window title.
    var titleLabel: String { displayName }

    /// Identity that survives re-plugging into another port: the USB serial number when
    /// present, else the location ID.
    var persistentKey: String {
        if let serial = serialNumber, !serial.isEmpty { return "serial:" + serial }
        return "location:" + videoDevice.locationID.lowercased()
    }
}

extension OpenterfaceDeviceCandidate: Equatable {
    static func == (lhs: OpenterfaceDeviceCandidate, rhs: OpenterfaceDeviceCandidate) -> Bool {
        lhs.id == rhs.id &&
        lhs.index == rhs.index &&
        lhs.controlLocationID == rhs.controlLocationID &&
        lhs.serialPortPath == rhs.serialPortPath &&
        lhs.serialNumber == rhs.serialNumber
    }
}

/// Tracks which Openterface unit this process is bound to.
///
/// Each process serves exactly one device. By default (no pin) the legacy behaviour is kept:
/// the first detected device group wins. A pin can come from the launch arguments
/// (`--video-location 0x00113400 --serial /dev/cu.usbmodem113201`) or from the UI
/// (Control ▸ Device menu, Settings ▸ Device & Connection). The pin is deliberately
/// held in memory only: `UserDefaults` is shared by every instance of the app, so
/// persisting it would make all instances fight over the same unit.
final class DeviceSelectionManager: ObservableObject {
    static let shared = DeviceSelectionManager()

    static let selectionDidChange = Notification.Name("DeviceSelectionDidChange")

    static let videoLocationArgument = "--video-location"
    static let serialPathArgument = "--serial"

    /// Device groups detected by the last USB scan, in a UI friendly form.
    @Published private(set) var candidates: [OpenterfaceDeviceCandidate] = []
    /// Location ID ("0x%08x") of the video chip this process is pinned to, if any.
    @Published private(set) var pinnedVideoLocationID: String?
    /// Serial port callout path this process is pinned to, if any.
    @Published private(set) var pinnedSerialPortPath: String?

    // Copies of the pins that can be read safely from background queues
    // (USB rescans and the serial connection loop run off the main thread).
    private let pinLock = NSLock()
    private var pinnedVideoLocationIDSnapshot: String?
    private var pinnedSerialPortPathSnapshot: String?

    // `applyLaunchArguments` runs before the dependency container (and thus the logger)
    // is set up, so its message is kept here and emitted on the first USB scan.
    private var pendingLaunchLogMessage: String?

    // Units driven by other live instances of this app (see "Cross-instance unit claims").
    @Published private(set) var unitKeysInUseByOtherInstances: Set<String> = []
    private let claimLock = NSLock()
    private var claimedUnitKey: String?
    private var unitKeysInUseSnapshot: Set<String> = []

    private init() {}

    // MARK: - Pin state

    var isPinned: Bool {
        pinnedVideoLocationID != nil || pinnedSerialPortPath != nil
    }

    /// Candidate that matches the current pin (nil when running in automatic mode or the
    /// pinned device is not connected).
    var pinnedCandidate: OpenterfaceDeviceCandidate? {
        guard isPinned else { return nil }
        return candidates.first { isActive($0) }
    }

    /// Candidate currently driving this process, taken from the chip references that
    /// `USBDevicesManager` actually bound (in automatic mode that is not necessarily the
    /// first entry of `candidates`).
    var activeCandidate: OpenterfaceDeviceCandidate? {
        let boundVideo = AppStatus.videoChipDevice?.locationID.lowercased()
        let boundControl = AppStatus.controlChipDevice?.locationID.lowercased()
        if let bound = candidates.first(where: { candidate in
            (boundVideo != nil && candidate.videoLocationID?.lowercased() == boundVideo)
                || (boundVideo == nil && boundControl != nil && candidate.controlLocationID?.lowercased() == boundControl)
        }) {
            return bound
        }
        return isPinned ? pinnedCandidate : nil
    }

    func isActive(_ candidate: OpenterfaceDeviceCandidate) -> Bool {
        activeCandidate?.id == candidate.id
    }

    /// Thread-safe accessor used by `USBDevicesManager`.
    func currentPinnedVideoLocationID() -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinnedVideoLocationIDSnapshot
    }

    /// Thread-safe accessor used by `SerialPortManager`.
    func currentPinnedSerialPortPath() -> String? {
        pinLock.lock(); defer { pinLock.unlock() }
        return pinnedSerialPortPathSnapshot
    }

    /// Suffix appended to the main window title so that several instances can be told apart.
    var windowTitleSuffix: String {
        guard isPinned else { return "" }
        if let candidate = pinnedCandidate {
            return " [\(candidate.titleLabel)]"
        }
        if let video = pinnedVideoLocationID {
            return " [\(DeviceSelectionManager.shortLocationID(video))]"
        }
        if let serial = pinnedSerialPortPath {
            return " [\((serial as NSString).lastPathComponent)]"
        }
        return ""
    }

    private func storePins(video: String?, serial: String?) {
        pinLock.lock()
        pinnedVideoLocationIDSnapshot = video
        pinnedSerialPortPathSnapshot = serial
        pinLock.unlock()

        let publish = {
            self.pinnedVideoLocationID = video
            self.pinnedSerialPortPath = serial
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    // MARK: - Launch arguments

    /// Reads `--video-location <id>` and `--serial <path>` (also the `=` forms) from the
    /// process arguments. Must be called before the first USB scan.
    func applyLaunchArguments(_ arguments: [String] = CommandLine.arguments) {
        var video: String?
        var serial: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let next: String? = index + 1 < arguments.count ? arguments[index + 1] : nil

            if argument == DeviceSelectionManager.videoLocationArgument, let value = next {
                video = DeviceSelectionManager.normalizeLocationID(value)
                index += 1
            } else if argument.hasPrefix(DeviceSelectionManager.videoLocationArgument + "=") {
                let value = String(argument.dropFirst(DeviceSelectionManager.videoLocationArgument.count + 1))
                video = DeviceSelectionManager.normalizeLocationID(value)
            } else if argument == DeviceSelectionManager.serialPathArgument, let value = next {
                serial = value
                index += 1
            } else if argument.hasPrefix(DeviceSelectionManager.serialPathArgument + "=") {
                serial = String(argument.dropFirst(DeviceSelectionManager.serialPathArgument.count + 1))
            }
            index += 1
        }

        guard video != nil || serial != nil else { return }
        storePins(video: video, serial: serial)
        pendingLaunchLogMessage = "Device pin from launch arguments: video=\(video ?? "auto") serial=\(serial ?? "auto")"
    }

    /// Accepts "0x1134", "0x00113400", "113400" or a decimal number and returns the
    /// canonical "0x%08x" form used by `USBDeviceInfo.locationID`.
    static func normalizeLocationID(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") {
            text = String(text.dropFirst(2))
            guard let value = UInt32(text, radix: 16) else { return nil }
            return String(format: "0x%08x", value)
        }
        if let decimal = UInt32(text) {
            return String(format: "0x%08x", decimal)
        }
        if let value = UInt32(text, radix: 16) {
            return String(format: "0x%08x", value)
        }
        return nil
    }

    /// Location prefix shared by every function of one physical unit.
    ///
    /// An Openterface unit is an internal USB hub whose children differ only in the last
    /// non-zero nibble of their location ID (e.g. hub 0x00113000, serial 0x00113200,
    /// video 0x00113400). Dropping that nibble gives a key ("0x00113") that is the same for
    /// the video chip and the control chip of one unit and different for a second unit
    /// plugged into the next port (0x00114…).
    static func unitPrefix(_ locationID: String) -> String {
        var text = locationID.lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        while text.count > 1 && text.hasSuffix("0") { text.removeLast() }
        if text.count > 1 { text.removeLast() }
        return "0x" + text
    }

    /// Port path encoded in a location ID: "0x00243000" -> [2, 4, 3].
    static func portPath(_ locationID: String) -> [Int] {
        var text = locationID.lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        // First byte is the bus number; the remaining nibbles are port numbers, zero padded.
        let nibbles = text.count > 2 ? Array(text.dropFirst(2)) : []
        var path: [Int] = []
        for ch in nibbles {
            guard let value = Int(String(ch), radix: 16), value != 0 else { break }
            path.append(value)
        }
        return path
    }

    /// Claim/selection key of a unit: the video chip location, else the control chip location.
    static func unitKey(video: USBDeviceInfo?, control: USBDeviceInfo?) -> String {
        (video?.locationID ?? control?.locationID ?? "none").lowercased()
    }

    struct UnitPair {
        let video: USBDeviceInfo?
        let control: USBDeviceInfo?
        /// How the pair was established (for logs): "hub", "port" or "single".
        let pairing: String
        var key: String { DeviceSelectionManager.unitKey(video: video, control: control) }
    }

    /// Pairs video chips with control chips into physical units.
    ///
    /// 1. Same internal hub (location prefix): the USB 2.0 case, e.g. serial 0x00113200 and
    ///    video 0x00113400 under hub 0x00113000.
    /// 2. Same physical port on the USB 3 tree: an MS2130S attached over USB 3 enumerates on
    ///    the SuperSpeed hub instead of the unit's internal USB 2 hub (e.g. video 0x00243000
    ///    while the serial sits under hub 0x00113000). The port path of the video and of the
    ///    control chip's hub then have the same depth and the same last port number.
    /// 3. Anything left stays unpaired.
    static func pairUnits(in devices: [USBDeviceInfo], using usb: USBDevicesManager) -> [UnitPair] {
        let videos = devices
            .filter { usb.isOpenterfaceVideoChipset(vendorId: $0.vendorID, productId: $0.productID) }
            .sorted { $0.locationID.lowercased() < $1.locationID.lowercased() }
        var controls = devices
            .filter { usb.isOpenterfaceControlChipset(vendorId: $0.vendorID, productId: $0.productID) }
            .sorted { $0.locationID.lowercased() < $1.locationID.lowercased() }

        var pairs: [UnitPair] = []
        var unpairedVideos: [USBDeviceInfo] = []

        for video in videos {
            let prefix = unitPrefix(video.locationID)
            if let index = controls.firstIndex(where: { unitPrefix($0.locationID) == prefix }) {
                pairs.append(UnitPair(video: video, control: controls.remove(at: index), pairing: "hub"))
            } else {
                unpairedVideos.append(video)
            }
        }

        for video in unpairedVideos {
            let videoPath = portPath(video.locationID)
            let match = controls.firstIndex { control in
                let hubPath = portPath(unitPrefix(control.locationID))
                return !videoPath.isEmpty && videoPath.count == hubPath.count && videoPath.last == hubPath.last
            }
            if let index = match {
                pairs.append(UnitPair(video: video, control: controls.remove(at: index), pairing: "port"))
            } else {
                pairs.append(UnitPair(video: video, control: nil, pairing: "single"))
            }
        }

        for control in controls {
            pairs.append(UnitPair(video: nil, control: control, pairing: "single"))
        }
        return pairs.sorted { $0.key < $1.key }
    }

    // MARK: - Nicknames (shared by all instances through UserDefaults)

    private static let nicknamesDefaultsKey = "openterfaceDeviceNicknames"

    func nickname(for candidate: OpenterfaceDeviceCandidate) -> String? {
        let store = UserDefaults.standard.dictionary(forKey: DeviceSelectionManager.nicknamesDefaultsKey) as? [String: String]
        return store?[candidate.persistentKey]
    }

    func setNickname(_ nickname: String, for candidate: OpenterfaceDeviceCandidate) {
        var store = UserDefaults.standard.dictionary(forKey: DeviceSelectionManager.nicknamesDefaultsKey) as? [String: String] ?? [:]
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            store.removeValue(forKey: candidate.persistentKey)
        } else {
            store[candidate.persistentKey] = trimmed
        }
        UserDefaults.standard.set(store, forKey: DeviceSelectionManager.nicknamesDefaultsKey)
        objectWillChange.send()
    }

    /// "0x00113400" -> "0x1134"
    static func shortLocationID(_ locationID: String) -> String {
        var text = locationID.lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        while text.count > 1 && text.hasSuffix("0") { text.removeLast() }
        return "0x" + text
    }

    // MARK: - Candidates

    /// Rebuilds the candidate list from `AppStatus.groupOpenterfaceDevices`.
    /// Safe to call from any thread; publishing happens on the main thread.
    /// Emits the launch-argument message once the logger is available.
    func flushPendingLaunchLog() {
        if let message = pendingLaunchLogMessage {
            pendingLaunchLogMessage = nil
            logger.log(content: message)
        }
    }

    func refreshCandidates(using usb: USBDevicesManager) {
        flushPendingLaunchLog()
        let serialByLocation = SerialPortLocator.usbLocationIDsByCalloutPath()

        var built: [OpenterfaceDeviceCandidate] = []
        for unit in DeviceSelectionManager.pairUnits(in: AppStatus.USBDevices, using: usb) {
            guard let video = unit.video else { continue }   // control-only entries are not selectable
            var serialPath: String?
            if let control = unit.control {
                serialPath = serialByLocation.first { $0.value.lowercased() == control.locationID.lowercased() }?.key
            }
            built.append(OpenterfaceDeviceCandidate(id: video.locationID.lowercased(),
                                                    index: built.count,
                                                    videoDevice: video,
                                                    controlDevice: unit.control,
                                                    serialPortPath: serialPath))
        }

        let publish = {
            if self.candidates != built {
                self.candidates = built
            }
        }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }

    // MARK: - Selection

    /// Pins this process to `candidate` and reconnects video, HID and serial.
    func select(_ candidate: OpenterfaceDeviceCandidate) {
        logger.log(content: "Device selection: pin to \(candidate.displayName) video=\(candidate.videoLocationID ?? "-") serial=\(candidate.serialPortPath ?? "-")")
        storePins(video: candidate.videoLocationID, serial: candidate.serialPortPath)
        reconnectAfterSelectionChange()
    }

    /// Clears the pin and goes back to the legacy "first detected device" behaviour.
    func selectAutomatic() {
        guard isPinned else { return }
        logger.log(content: "Device selection: back to automatic")
        storePins(video: nil, serial: nil)
        reconnectAfterSelectionChange()
    }

    private func reconnectAfterSelectionChange() {
        let run = {
            let serialPortManager = SerialPortManager.shared
            let videoManager = VideoManager.shared
            let hidManager = HIDManager.shared

            // Tear down everything bound to the previous unit.
            serialPortManager.closeSerialPort()
            hidManager.closeHID()
            videoManager.resetVideoInputsForDeviceChange()

            // Re-resolve video/control chip devices with the new pin applied.
            USBDevicesManager.shared.update()

            // Bring the new unit up.
            hidManager.startHID()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                videoManager.prepareVideo()
                serialPortManager.tryConnectOpenterface()
            }

            NotificationCenter.default.post(name: DeviceSelectionManager.selectionDidChange, object: nil)
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    // MARK: - Cross-instance unit claims

    // Each instance writes "<unitKey>.claim" (containing its pid) into a folder shared by all
    // instances of this bundle. An instance started without a pin skips units whose claim
    // belongs to another live instance, so a plain `open -n` second copy automatically takes
    // the next free unit instead of fighting over the first one.

    private static var claimsDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "openterface", isDirectory: true)
            .appendingPathComponent("instance-claims", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func claimFile(for unitKey: String) -> URL? {
        claimsDirectory?.appendingPathComponent(unitKey + ".claim")
    }

    /// Returns true when `pid` is a live process running this same app bundle.
    private static func isLiveInstance(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// Unit keys claimed by other live instances. Claims left behind by dead processes are removed.
    /// Safe to call from any thread.
    @discardableResult
    func unitKeysClaimedByOtherInstances() -> Set<String> {
        var keys = Set<String>()
        if let directory = DeviceSelectionManager.claimsDirectory,
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let myPID = ProcessInfo.processInfo.processIdentifier
            for file in files where file.pathExtension == "claim" {
                let key = file.deletingPathExtension().lastPathComponent
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                if pid == myPID { continue }
                if DeviceSelectionManager.isLiveInstance(pid) {
                    keys.insert(key)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }

        claimLock.lock()
        unitKeysInUseSnapshot = keys
        claimLock.unlock()

        let publish = {
            if self.unitKeysInUseByOtherInstances != keys {
                self.unitKeysInUseByOtherInstances = keys
            }
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
        return keys
    }

    /// Thread-safe copy of the last claim scan.
    func currentUnitKeysInUseByOtherInstances() -> Set<String> {
        claimLock.lock(); defer { claimLock.unlock() }
        return unitKeysInUseSnapshot
    }

    /// Records that this process drives `unitKey` (nil releases the current claim).
    func claimUnit(_ unitKey: String?) {
        claimLock.lock(); defer { claimLock.unlock() }
        guard unitKey != claimedUnitKey else { return }
        if let previous = claimedUnitKey, let file = DeviceSelectionManager.claimFile(for: previous) {
            try? FileManager.default.removeItem(at: file)
        }
        claimedUnitKey = unitKey
        if let unitKey = unitKey, let file = DeviceSelectionManager.claimFile(for: unitKey) {
            try? "\(ProcessInfo.processInfo.processIdentifier)\n".write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func releaseClaim() {
        claimUnit(nil)
    }

    // MARK: - Multi instance helpers

    /// Launches another copy of this app pinned to `candidate`.
    func openInNewInstance(_ candidate: OpenterfaceDeviceCandidate, completion: ((Error?) -> Void)? = nil) {
        var arguments: [String] = []
        if let video = candidate.videoLocationID {
            arguments += [DeviceSelectionManager.videoLocationArgument, video]
        }
        if let serial = candidate.serialPortPath {
            arguments += [DeviceSelectionManager.serialPathArgument, serial]
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments

        logger.log(content: "Launching new instance for \(candidate.displayName) with arguments \(arguments)")
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error = error {
                logger.log(content: "Failed to launch new instance: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { completion?(error) }
        }
    }

    /// Zero-based index of this process among the running instances of the app
    /// (0 for the first/only instance). Used to cascade windows so they do not overlap.
    static func runningInstanceOrdinal() -> Int {
        guard let bundleID = Bundle.main.bundleIdentifier else { return 0 }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return instances.firstIndex { $0.processIdentifier == myPID } ?? max(instances.count - 1, 0)
    }
}

/// Maps serial port callout paths (e.g. /dev/cu.usbmodem113201) to the USB location ID
/// of the device they belong to, by walking up the IORegistry from each IOSerialBSDClient.
enum SerialPortLocator {
    static func usbLocationIDsByCalloutPath() -> [String: String] {
        var result: [String: String] = [:]
        guard let matching = IOServiceMatching("IOSerialBSDClient") else { return result }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            if let locationID = usbLocationID(startingFrom: service) {
                result[path] = locationID
            }
        }
        return result
    }

    /// USB location ID ("0x%08x") of the serial port at `calloutPath`, if it is a USB device.
    static func usbLocationID(forCalloutPath calloutPath: String) -> String? {
        usbLocationIDsByCalloutPath()[calloutPath]
    }

    private static func usbLocationID(startingFrom service: io_object_t) -> String? {
        var current: io_object_t = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        // IOSerialBSDClient -> AppleUSB*Data -> IOUSBHostInterface -> IOUSBHostDevice.
        // Both the interface and the device carry the same "locationID" value.
        for _ in 0..<16 {
            if let number = IORegistryEntryCreateCFProperty(current, "locationID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return String(format: "0x%08x", number.uint32Value)
            }
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
